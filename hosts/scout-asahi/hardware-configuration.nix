# asahi hardware — PLACEHOLDER until nixos-apple-silicon provides real modules.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";   # TODO
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";     # TODO
    fsType = "vfat";
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
