# warden-arch — the 5800H/16GB/1TB homeserver. Deployed (fresh NixOS install
# 2026-10-08, plan 11); runs immich + radicale/wycal + caddy ingress + the
# dev docker daemon (used over SSH from the Mac). Matrix and speaches were
# torn down 2026-11-08 (user decisions — data deleted, no archive). Hardware-configuration regenerated at install.
{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    ../../modules/lab-cache.nix # makerspace attic cache (pull + push)
    ../../modules/ingress.nix   # caddy + *.ts.wyli.tech wildcard (deSEC DNS-01)
    ../../modules/immich.nix    # plan 12 §2 — native immich, fresh library
    ../../modules/immich-backup.nix # DRAFT off — library+pgdump restic to the pi; card too small, see header
    ../../modules/devlanes.nix  # plan 12 §4 — dev-test lane deps + slice
    ../../modules/ai.nix       # pi agent + aichat (MCP-first, empty profiles) — 2026-10-26
    ../../modules/git.nix       # system git identity (/etc/gitconfig) — commits link to wylited
    ../../modules/caldav.nix    # radicale (moved here 2026-10-27; pi = flaky cold-standby)
    ../../modules/hardening.nix # fleet baseline: key-only sshd + journald caps (2026-10-26 audit)
    inputs.wycal.nixosModules.wycal  # cal.ts.wyli.tech UI — darkhttpd on :8423 (2026-10-28)
    inputs.dsh.nixosModules.dsh     # ai.ts.wyli.tech — dsh web harness (:3080/:3081 blue-green, git-checkout service, 2026-11-09)
  ];

  # caddy terminates the services that run here (dav gets a hand-rolled vhost
  # below — it needs CORS for the wycal UI):
  wyli.ingress.routes = {
    "immich.ts.wyli.tech" = 2283;
    "cal.ts.wyli.tech"    = 8423;  # wycal static UI (services.wycal, darkhttpd)
    "ai.ts.wyli.tech"     = [ 3080 3081 ];  # dsh web UI (services.dsh), blue-green slots a/b — caddy health-checks both
  };
  # dav.ts.wyli.tech: radicale is LOCAL (pi = cold-standby, 2026-10-27). CORS
  # keeps local-dev UIs (wycal) working cross-origin; CalDAV needs the
  # headers and PROPFIND/OPTIONS methods listed.
  services.caddy.virtualHosts = lib.mkIf (builtins.pathExists "/etc/nix/acme-desec-env") {
    "https://dav.ts.wyli.tech" = {
      useACMEHost = "ts.wyli.tech";
      extraConfig = ''
        reverse_proxy 127.0.0.1:5232
        @cors_preflight method OPTIONS
        respond @cors_preflight 204
        header Access-Control-Allow-Origin "*"
        header Access-Control-Allow-Methods "GET, PUT, PROPFIND, OPTIONS, DELETE, REPORT, MKCOL, MOVE"
        header Access-Control-Allow-Headers "Authorization, Depth, Content-Type, If-Match, If-None-Match, Prefer"
        header Access-Control-Expose-Headers "ETag, DAV"
      '';
    };
  };

  # wycal — the CalDAV/CardDAV web client (github:wylited/wycal), nix-built
  # static site on :8423 behind the cal.ts.wyli.tech vhost above. Talks
  # cross-origin to radicale via dav.ts.wyli.tech (CORS there).
  services.wycal = {
    enable = true;
    package = inputs.wycal.packages.x86_64-linux.default;
  };

  # dsh — web AI harness (github:wylited/deepseek-harness, branch wyli).
  # Binds 127.0.0.1:3080; caddy fronts it as ai.ts.wyli.tech (tailnet only).
  # Provisions itself from a git checkout of the fork on first boot (clone +
  # node 24.9.0 + pnpm install + branded client build — expect a LONG first
  # start), auto-updates daily via dsh-update.timer (fast-forward only).
  # Provider keys go in /etc/nix/dsh-env (0600, optional — service runs
  # degraded without it).
  services.dsh.enable = true;

  # dsh-update setpriv-drops to the dsh uid inside a root wrapper, but the
  # module's StateDirectory=dsh with no User= makes systemd re-own
  # /var/lib/dsh to root on every update run — locking the dsh user out of
  # its own state (observed 2026-11-09: inner died on ".lock: Permission
  # denied"). the dsh slots (dsh@a, boot slot) already own creation/ownership
  # of the dir; clear the setting here (empty value renders as a reset).
  #
  # The module's provision script prefixes DSH_CLIENT_* onto `pnpm install`
  # only — `pnpm run build` runs bare and falls back to git-derived branding
  # (`0.2.2-rc.1-<shorthash>-dirty`; observed 2026-11-09). Exporting the same
  # values at the unit level reaches the build in both entry paths (slot
  # ExecStartPre and dsh-update) without touching the fork: repositoryCommit
  # Hash honours the `wyli` sentinel and DSH_CLIENT_GIT_DIRTY=false suppresses
  # the dirty suffix. Runtime effect is benign: the host reads
  # DSH_CLIENT_COMMIT_HASH only for release metadata.
  systemd.services =
    {
      dsh-update.serviceConfig = {
        StateDirectory = lib.mkForce "";
        Environment = [
          "DSH_CLIENT_VERSION=0.2.2-rc.1"
          "DSH_CLIENT_COMMIT_HASH=wyli"
          "DSH_CLIENT_GIT_DIRTY=false"
        ];
      };
    } // lib.genAttrs [ "dsh@a" "dsh@b" ] (_: {
      serviceConfig.Environment = [
        "DSH_CLIENT_VERSION=0.2.2-rc.1"
        "DSH_CLIENT_COMMIT_HASH=wyli"
        "DSH_CLIENT_GIT_DIRTY=false"
      ];
    });

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
  # so sudo must not ask (ssh stays key-only).
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
  # ================= dev docker daemon =================
  # dockerd is the dev server: use it from the Mac over SSH — no extra ports,
  # no TLS setup, SSH keys are the auth. On the Mac:
  #   docker context create warden --docker "host=ssh://wyli@warden"
  #   docker --context warden ps
  # (wyli is in the docker group; `wyli@warden` is the flake's own deploy
  # checkout, so treat warden's docker as semi-production — it shares the box
  # with immich.) immich-ML runs under PODMAN, not this daemon — see
  # modules/immich.nix.

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
      root = {
        SUBVOLUME = "/";
        # timeline was silently dead until 2026-10-28: NixOS writes ONLY the
        # attrs below into /etc/snapper/configs/*, and without TIMELINE_CREATE
        # the hourly timer no-ops. .snapshots subvolumes are also required —
        # created by hand on-box (btrfs subvolume create /{,home/}.snapshots);
        # snapper never creates them itself.
        TIMELINE_CREATE = true;
        TIMELINE_LIMIT_HOURLY = "24";
        TIMELINE_LIMIT_DAILY = "7";
        TIMELINE_LIMIT_WEEKLY = "4";
        TIMELINE_LIMIT_MONTHLY = "3";
      };
      home = {
        SUBVOLUME = "/home";
        TIMELINE_CREATE = true;
        TIMELINE_LIMIT_HOURLY = "24";
        TIMELINE_LIMIT_DAILY = "7";
        TIMELINE_LIMIT_WEEKLY = "4";
        TIMELINE_LIMIT_MONTHLY = "3";
      };
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
  # silently strip the lab-cache wiring. Re-enable once the token is baked
  # into the public eval (or dropped) — until then rebuild from the local
  # checkout.
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
