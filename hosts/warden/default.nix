# warden-arch — the 5800H/16GB/1TB homeserver. Deployed (fresh NixOS install
# 2026-10-08, plan 11); runs immich + speaches + matrix + fallback DNS + the
# ai stack (modules/ai.nix). Hardware-configuration regenerated at install.
{ config, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  # matrix re-enabled 2026-10-26: FRESH deploy (no restore — old data died
  # with Arch; Beeper replacement per plan 10). serverName = matrix.wyli.tech
  # (plain-http caddy ingress, no tailscale serve — user decision 2026-10-26).
  ./matrix.nix # Synapse + mautrix bridges; see ~/nix-migration/10-matrix-on-warden.md
    ../../modules/dns.nix       # FALLBACK resolver (2026-10-25): identical module+rewrites as the
                                # pi — Tailscale console lists both as wyli.tech nameservers; git
                                # is the single source of truth, drift is impossible by construction
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    ../../modules/lab-cache.nix # makerspace attic cache (pull + push)
    ../../modules/ingress.nix   # plan 12 §0 — caddy + *.wyli.tech wildcard (no-ops without CF token)
    ../../modules/immich.nix    # plan 12 §2 — native immich, fresh library
    ../../modules/immich-backup.nix # DRAFT off — library+pgdump restic to the pi; card too small, see header
    ../../modules/whisper.nix   # plan 12 §8 — GPU Mode B + speaches
    ../../modules/devlanes.nix  # plan 12 §4 — dev-test lane deps + slice
    ../../modules/ai.nix       # pi agent + aichat (MCP-first, empty profiles) — 2026-10-26
    ../../modules/git.nix       # system git identity (/etc/gitconfig) — commits link to wylited
    ../../modules/hardening.nix # fleet baseline: key-only sshd + journald caps (2026-10-26 audit)
  ];

  # dns.nix + caldav.nix MOVED to artificer (2026-10-16, user decision — small
  # always-on services shouldn't ride the big server). This host's caddy only
  # terminates what actually runs here:
  wyli.ingress.routes = {
    "immich.wyli.tech" = 2283;
    "stt.wyli.tech" = 8000;
    "matrix.wyli.tech" = 8008;   # synapse — plain http, tailnet-only (2026-10-26)
  };

  # latest immich from the rolling input (fleet nixpkgs pin ships 3.0.3;
  # fresh instance = zero migration risk) — 2026-10-26
  services.immich.package =
    inputs.nixpkgs-immich.legacyPackages.x86_64-linux.immich;

  # ================= backup target for artificer (the pi) ====================
  # The pi's nightly restic lands here via sftp over the tailnet — see
  # modules/pi-backup.nix (DRAFT, enable still off there; this dir + rule are
  # harmless to deploy ahead of it). tmpfiles owns the directory; the hourly
  # root snapper config above also snapshots /srv/backups, so a botched prune
  # on the pi is undoable here for at least an hour after the fact.
  systemd.tmpfiles.rules = [
    "d /srv/backups/artificer 0700 wyli wyli -"
  ];
  # TODO (with step 3 of pi-backup.nix's bring-up list): append the pi's key
  # to users.users.wyli.openssh.authorizedKeys.keys, restricted to sftp:
  #   "restrict ssh-ed25519 <contents of the pi's /etc/nix/pi-backup_ed25519.pub> pi-backup@artificer"
  # (uid 1000 above already keeps ownership stable across restores.)

  # ================= boot / basics =================
  boot.loader.systemd-boot.enable = true;          # matches current Arch bootloader
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 5; # /boot is only 1 GiB

  networking.hostName = "warden-arch";   # matches the tailnet node name (user pref 2026-10-25)
  networking.networkmanager.enable = true;
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];          # tailnet traffic unfiltered
    allowedTCPPorts = [ 22 22000 ];                # ssh + syncthing; immich :2283 via tailscale
    allowedUDPPorts = [ 22000 21027 ];             # syncthing quic + local discovery
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # nvidia driver (modules/whisper.nix) is the only unfree package on warden
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "nvidia-x11" "nvidia-persistenced" "nvidia-kernel-modules" ];
  # plan 01/03 hygiene — the Mac's 103 generations are the cautionary tale:
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };
  nix.settings.auto-optimise-store = true;

  # ================= build & store on the lab builder ==========================
  # Whole-world x86-64-v3 is OFF: eez156 (Ivy Bridge Xeon, pre-AVX2) would have
  # to execute a v3-tainted toolchain — SIGILL. Baseline userland + zen kernel
  # + scx ships and substitutes from the lab attic. Revisit v3 later as a
  # targeted leaf-package overlay, or whole-world once an AVX2+ builder exists
  # (any Haswell+/Ryzen/x86 VPS via a second nix.buildMachines entry) — or let
  # warden itself (5800H has AVX2) build the v3 delta after the reflash.

  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = "ssh.ecemaker.space";
      sshUser = "ecemakers";
      protocol = "ssh-ng";
      systems = [ "x86_64-linux" ];
      supportedFeatures = [ "kvm" "big-parallel" "benchmark" "nixos-test" ];
      speedFactor = 4;
      # No `mandatory` in this nixpkgs — default Nix behavior already falls
      # back to local builds when the builder is unreachable.
      # Generate key at install: ssh-keygen -f /etc/nix/ecemaker_build_ed25519,
      # then append the pubkey to ecemakers@eez156:~/.ssh/authorized_keys.
      sshKey = "/etc/nix/ecemaker_build_ed25519";
    }
  ];

  # ================= tailscale (exit node; identity via state copy) =================
  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "server";   # exit node / subnet router
    # Fresh identity: the state copy died with the Arch wipe — after first
    # boot run `sudo tailscale up --advertise-exit-node` and re-auth via browser.
  };

  services.openssh = {
    enable = true;
    # baseline (PasswordAuthentication/KbdInteractiveAuthentication false,
    # PermitRootLogin prohibit-password) lives in modules/hardening.nix
    # host keys copied from Arch /etc/ssh/ssh_host_* at install to keep identity
  };
  # headless bring-up parity with artificer: no password exists at first boot,
  # so sudo must not ask (ssh stays key-only). Tighten with sops (plan 03).
  security.sudo.wheelNeedsPassword = false;

  # ================= docker: immich only (vvvm decommissioned) =================
  virtualisation.docker.enable = true;
  environment.systemPackages = with pkgs; [
    docker-compose
    fish
    helix
    git
    tailscale
    btrfs-progs
    ryzenadj
  ];
  # docker is the runtime for: immich-ML (cuda), speaches, mongo per dev lane.
  # immich itself is NATIVE now — see ../../modules/immich.nix (plan 12 §2);
  # the old compose stack is gone by decision, no restore.

  # arm64 on demand: builds artificer-nixos's sd-image locally + arm64 docker
  # images via qemu (plan 12 §9). Emulated = slow, fine for images/closures.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # ================= services =================
  services.syncthing = {
    enable = true;
    user = "wyli";
    dataDir = "/home/wyli";
    configDir = "/home/wyli/.config/syncthing";    # existing config survives (shared /home)
  };


  services.redis.servers."" = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";            # matches Arch (loopback only)
  };

  # Shared PG cluster (immich + synapse + dev lanes, 15 GiB host). Mirrors
  # immich's own postgres tuning (base-images postgresql.ssd.conf) at this
  # scale — live values before: shared_buffers 320 MB / work_mem 4 MB, which
  # throttles the Takeout-import job storm (thumbs + ML queue + WAL churn).
  services.postgresql.settings = {
    shared_buffers = "1GB";
    effective_cache_size = "6GB";    # planner hint only, no allocation
    work_mem = "8MB";                # ×~50 real conns stays well under budget
    max_wal_size = "5GB";            # fewer checkpoints during bulk imports
    random_page_cost = 1.2;          # NVMe (immich ssd.conf value)
    effective_io_concurrency = 200;  # NVMe (immich ssd.conf value)
  };

  services.tlp.enable = true;      # laptop power (Arch: tlp + tlp-pd + tlp-rdw)

  zramSwap.enable = true;          # Arch: zram-generator, 4G
  # pressure kills the fattest cgroup instead of kernel-OOM roulette
  # (PLAN §11 — every MemoryMax sits ABOVE real working set; caps below it
  # cause restart loops, the ms.api production lesson)
  systemd.oomd.enable = true;

  # ================= desktop responsiveness (omarchy-style) =====================
  # zen is binary-cached and sched_ext-capable. The CachyOS kernel (clang
  # ThinLTO, BORE) is an opt-in upgrade via github:xddxdd/nix-cachyos-kernel —
  # not in nixpkgs since Chaotic-Nyx archived (2025-12); the eez156 builder
  # makes its LTO cost a non-issue if benchmarks ever justify it.
  boot.kernelPackages = pkgs.linuxPackages_zen; # sched_ext-capable zen kernel
  services.scx = {
    enable = true;                 # userspace sched_ext scheduler daemon
    scheduler = "scx_bpfland";    # interactive default; scx_lavd for gaming
  };
  boot.kernelParams = [ "zswap.enabled=0" ]; # zram + zswap would double-compress
  boot.initrd.kernelModules = [ "amdgpu" ];  # early KMS for the Cezanne iGPU
  # Arch firmware parity (amd-ucode + linux-firmware):
  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  services.snapper = {
    snapshotInterval = "hourly";
    cleanupInterval = "1d";
    configs = {
      root = { SUBVOLUME = "/"; };
      home = { SUBVOLUME = "/home"; };
    };
  };

  # ryzenadj — ported from Arch unit (values as of 2026-08-23; the ExecStart line
  # was truncated in recon — re-copy verbatim from
  # /etc/systemd/system/ryzenadj.service during install):
  systemd.services.ryzenadj = {
    description = "RyzenAdj Power Management";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.ExecStart = ""
      + "${pkgs.ryzenadj}/bin/ryzenadj"
      + " --stapm-limit=30000 --fast-limit=30000 --slow-limit=30000"
      + " --tctl-temp=75 --vrm-current=4500";
    # TODO: append any further args from the Arch unit
  };

  # Replaces the Arch nightly-update.timer. DISABLED for now: it evals the
  # github tree, which lacks the gitignored attic token, so a 02:00 run would
  # silently strip the lab-cache wiring. Re-enable once the token moves to
  # sops-nix (plan 03) — until then rebuild from the local checkout.
  # NOTE (verified 2026-10-25): a plain `--flake /home/wyli/Repos/nix-config`
  # is a git+file ref — flake.nix is then evaluated PURE, so
  # `builtins.pathExists "/etc/nix/attic-token.txt"` (lab-cache.nix) returns
  # false and the module silently no-ops — the rebuild produces the identical
  # generation. The working invocation evaluates the working tree impurely:
  #   sudo nixos-rebuild switch --flake "path:/home/wyli/Repos/nix-config#warden" --impure
  system.autoUpgrade = {
    enable = false;
    dates = "02:00";
    flake = "github:wylited/nix-config#warden";
    flags = [ "--commit-lock-file" ];
  };

  # ================= GPU =================
  # Mode B is ON — brought up in ../../modules/whisper.nix (plan 12 §8):
  # compute-only dGPU (amdgpu keeps the display path), RTD3 fine-grained
  # power management, nvidia container runtime for speaches + immich-ML.
  # VRAM is shared between them; see PLAN.md §11 for the budget.

  # ================= user =================
  users.users.wyli = {
    isNormalUser = true;
    # yescrypt hash at /etc/nix/warden-passwd (root:root 0600, NOT in git —
    # repo is public). Console/sudo login; sshd stays key-only + tailscale ssh.
    hashedPasswordFile = "/etc/nix/warden-passwd";
    uid = 1000;                                    # backup restore preserves ownership
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBuAd/BlQgZGZZ+6iAr0wsolROisfVsuvp+4h3KaARLJ wylited"
    ];
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBuAd/BlQgZGZZ+6iAr0wsolROisfVsuvp+4h3KaARLJ wylited"
  ];
  programs.fish.enable = true;

  # home-manager wiring lives in flake.nix (shared home/wyli.nix)

  system.stateVersion = "26.05";                   # set at first install, then never touch
}
