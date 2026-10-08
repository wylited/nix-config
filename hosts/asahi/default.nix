# asahi — NixOS on the M1 Pro (plan 05). EVAL STUB.
# Missing (add before install):
#   inputs.nixos-apple-silicon (github:nix-community/nixos-apple-silicon)
#   -> hardware.asahi.enable = true; + their bootloader modules (m1n1/u-boot,
#      NOT systemd-boot — the line below only keeps this stub eval-clean).
{ config, pkgs, inputs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;   # TODO: replace with apple-silicon boot chain

  networking.hostName = "asahi";
  networking.networkmanager.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };
  nix.settings.auto-optimise-store = true;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    authKeyFile = "/run/secrets/ts-authkey";   # sops-decoded, first activation only
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  users.users.wyli = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.fish;
  };
  programs.fish.enable = true;

  # Role (plan 03): native aarch64-linux builder for rpi5 images:
  #   nix.buildMachines / serve as builder target for scout-darwin

  system.stateVersion = "26.05";
}
