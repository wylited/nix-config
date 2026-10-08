# rpi5 hardware — sd-image modules define "/" (NIXOS_SD) and "/boot" (FIRMWARE)
# themselves; nothing to declare here until moving to a real installed config.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
