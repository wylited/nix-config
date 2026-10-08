# PLACEHOLDER — FRESH-DISK layout (plan 11): full wipe, new btrfs on nvme0n1p2
# with subvolumes @ (root) + @home. Devices are LABEL-based (btrfs label
# `warden`, ESP label `BOOT` — both set by the mkfs commands in plan 11), so
# nothing here needs editing after the format.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/warden";
    fsType = "btrfs";
    options = [ "subvol=@" "compress=zstd:3" "ssd" "discard=async" ];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-label/warden";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd:3" "ssd" "discard=async" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  swapDevices = [ ];   # zram via zramSwap.enable in default.nix

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
