# warden — Arch -> NixOS draft (plan 08)
# Eval-verified only; NOT yet installed anywhere. hardware-configuration.nix is a
# placeholder built from the observed Arch fstab — regenerate at install time.
{ config, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./matrix.nix # Synapse + mautrix bridges; see ~/nix-migration/10-matrix-on-warden.md
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    ../../modules/lab-cache.nix # makerspace attic cache (pull + push)
  ];

  # ================= boot / basics =================
  boot.loader.systemd-boot.enable = true;          # matches current Arch bootloader
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 5; # /boot is only 1 GiB

  networking.hostName = "warden";
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
    settings.PasswordAuthentication = false;
    # host keys copied from Arch /etc/ssh/ssh_host_* at install to keep identity
  };

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
  # immich: /home/wyli/apps/immich (compose + .env + library) is GONE with the
  # wipe — restore from the 2026-10-07 backup before `docker compose up -d`.
  # NOTE: compose references a caddy_net network + an (exited) caddy container —
  # verify whether caddy is wanted again or expose :2283 directly.

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

  services.tlp.enable = true;      # laptop power (Arch: tlp + tlp-pd + tlp-rdw)

  zramSwap.enable = true;          # Arch: zram-generator, 4G

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

  # replaces the Arch nightly-update.timer (whose target script no longer exists!)
  system.autoUpgrade = {
    enable = true;
    dates = "02:00";
    flake = "github:wylited/nix-config#warden";    # TODO: real repo URL when pushed
    flags = [ "--commit-lock-file" ];
  };

  # ================= GPU =================
  # Mode A (default, plan 08): headless — no NVIDIA driver loaded; the RTX 3050
  # is an Optimus 3D controller with no display outputs and self-suspends (~0 W).
  # Mode B (on demand), uncomment when CUDA/graphics is wanted:
  # hardware.graphics.enable = true;
  # services.xserver.videoDrivers = [ "amdgpu" "nvidia" ];
  # hardware.nvidia = {
  #   package = nvidiaPackages.stable;        # Ampere — mainline, no 580xx needed
  #   modesetting.enable = true;
  #   powerManagement.enable = true;
  #   powerManagement.finegrained = true;     # RTD3
  #   prime = {
  #     offload.enableOffloadCmd = true;      # `prime-run <app>`
  #     amdgpuBusId = "PCI:4:0:0";
  #     nvidiaBusId = "PCI:1:0:0";
  #   };
  # };

  # ================= user =================
  users.users.wyli = {
    isNormalUser = true;
    uid = 1000;                                    # backup restore preserves ownership
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClNgLOMFRXUOo87H7yR3hXgdEwci1sdSYHOh7P0p4Cb wyli@scout-darwin.local"
    ];
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIClNgLOMFRXUOo87H7yR3hXgdEwci1sdSYHOh7P0p4Cb wyli@scout-darwin.local"
  ];
  programs.fish.enable = true;

  # home-manager wiring lives in flake.nix (shared home/wyli.nix)

  system.stateVersion = "26.05";                   # set at first install, then never touch
}
