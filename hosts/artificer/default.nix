# artificer (an) — the rpi5, 8 GB, raw sd-image (plan 03). Archetype named
# 2026-10-11; hosting deferred. Route (decided 2026-10-11): build the image
# on warden via binfmt (scripts/provision-artificer.sh), dd to SD or USB
# SSD, boot, then nixos-rebuild --target-host artificer-nixos from warden.
# nixos-anywhere deliberately skipped — Pi kernels + kexec is the flaky
# combo, and this sd-image module already owns the Pi-5 firmware/boot files.
# Pi 5 boot files require nixos-unstable — verify the shared nixpkgs input is
# new enough at build time, else add a dedicated unstable input (plan 03 §5).
{ config, pkgs, inputs, ... }:

{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
    ./hardware-configuration.nix
  ];

  sdImage.compressImage = true;            # .img.zst out
  boot.zfs.forceImportRoot = false;        # silence 26.11 default warning (no zfs on this host)

  # Pi boots via firmware + extlinux, not systemd-boot:
  boot.loader.generic-extlinux-compatible.enable = true;

  networking.hostName = "artificer-nixos";   # the Debian boot is artificer-debian (outside this flake)
  networking.networkmanager.enable = true; # or wpa_supplicant for headless wifi

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    authKeyFile = "/run/secrets/ts-authkey";   # sops-decoded, first activation only
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    # TODO: bake a host key or a first-boot provisioning step (nixos-anywhere-style)
  };

  users.users.wyli = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.fish;
  };
  programs.fish.enable = true;

  environment.systemPackages = with pkgs; [
    libraspberrypi   # raspinfo, vcgencmd etc.
  ];

  system.stateVersion = "26.05";
}
