# artificer (an) — the rpi5, 8 GB, NixOS sd-image (plan 03). Hosting deferred
# until first flash; everything needed to build + flash + first-boot is ready.
#
# Route (decided 2026-10-11): build the image on warden via binfmt
# (scripts/provision-artificer.sh), dd to SD or USB SSD, boot ethernet, then
# `nixos-rebuild --target-host artificer-nixos` from warden. nixos-anywhere
# deliberately skipped — Pi kernels + kexec is the flaky combo, and this
# sd-image module already owns the Pi-5 firmware/boot files.
#
# Pi 5 support in the pinned nixpkgs (20260720) VERIFIED 2026-10-11: the
# sd-image module ships a [pi5] config.txt section (enable_uart=0, the UART
# ghost-input workaround), universal ubootRaspberryPiAarch64 u-boot.bin, and
# all bcm2712 DTBs (rpi-5-b, 500, cm5) into the firmware partition — no
# dedicated unstable input needed.
#
# Wired for first boot (no display, no password):
#   • ethernet DHCP via NetworkManager; WiFi firmware baked in — HDMI+keyboard
#     autologins wyli, then `nmcli device wifi connect <SSID>` for wifi-only spots
#   • ssh key-only, the wylited key baked in (wyli + root)
#   • passwordless sudo for wyli (headless bring-up tradeoff)
#   • tailscale: `sudo tailscale up` interactively after ssh
#   • external disk for storage-transfer work: DEFERRED by decision (2026-10-11)
#     — attach later as a plain mount + whatever service needs it
{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
    ./hardware-configuration.nix
    ../../modules/git.nix       # system git identity (/etc/gitconfig) — commits link to wylited
    ../../modules/hardening.nix # fleet baseline: key-only sshd + journald caps (2026-10-26 audit)
    ../../modules/pi-backup.nix # DRAFT off — nightly restic to warden; enable after key bring-up
  ];

  # ============ backup target for warden (immich library + pg dump) =========
  # warden's nightly restic lands here via sftp over the tailnet — see
  # modules/immich-backup.nix (DRAFT, enable still off there; this dir + rule
  # are harmless to deploy ahead of it). NOTE: the 58 GB card WILL be outgrown
  # once the Takeout import lands — treat this as a stopgap target only.
  systemd.tmpfiles.rules = [
    "d /srv/backups/immich 0700 wyli wyli -"
  ];
  # TODO (with step 3 of immich-backup.nix's bring-up list): append warden's
  # key to users.users.wyli.openssh.authorizedKeys.keys, restricted to sftp:
  #   "restrict ssh-ed25519 <contents of warden's /etc/nix/immich-backup_ed25519.pub> immich-backup@warden"
  # (`restrict` still allows the sftp subsystem; it only disables the exec
  # half of that module's size guard, which degrades to a logged NOTE.)

  # ================= resilience (SD card is the only disk) ===================
  # Journal cap: 64 MiB today, but nothing stopped growth and the SD card is
  # also /. Hard ceiling + retention so a chatty unit can't fill the card.
  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=30day
  '';

  sdImage.compressImage = true;            # .img.zst out
  boot.zfs.forceImportRoot = false;        # silence 26.11 default warning (no zfs on this host)

  # Pi boots via firmware + extlinux, not systemd-boot:
  boot.loader.generic-extlinux-compatible.enable = true;

  networking.hostName = "artificer-nixos";
  networking.networkmanager.enable = true; # ethernet DHCP out of the box

  # WiFi fallback (Pi 5 = same CYW43455 as Pi 4): brcmfmac is in the generic
  # aarch64 kernel (arm64 defconfig, as module) but the image ships no
  # firmware by default — this package brings the RPi-Distro blobs + the
  # Pi-5 nvram (brcmfmac43455-sdio.raspberrypi,5-model-b.txt).
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];

  # headless recovery: HDMI + keyboard drops straight into a wyli shell
  # (the image has NO passwords — ssh stays key-only), then:
  #   nmcli device wifi connect <SSID> password <pw>
  services.getty.autologinUser = "wyli";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    # first boot: ssh in, `sudo tailscale up`, done.
  };

  services.openssh = {
    enable = true;
    # baseline (PasswordAuthentication/KbdInteractiveAuthentication false,
    # PermitRootLogin prohibit-password) lives in modules/hardening.nix
  };

  # key baked in — this is the ONLY way in on first boot (no display, no password)
  users.users.wyli = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBuAd/BlQgZGZZ+6iAr0wsolROisfVsuvp+4h3KaARLJ wylited"
    ];
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBuAd/BlQgZGZZ+6iAr0wsolROisfVsuvp+4h3KaARLJ wylited"
  ];
  # headless bring-up: no password hash exists, so sudo must not ask for one.
  security.sudo.wheelNeedsPassword = false;

  programs.fish.enable = true;

  environment.systemPackages = with pkgs; [
    libraspberrypi   # raspinfo, vcgencmd etc.
  ];

  system.stateVersion = "26.05";
}
