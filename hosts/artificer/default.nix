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
# Wired for first boot (no display, no sops yet):
#   • ethernet DHCP via NetworkManager; WiFi firmware baked in — HDMI+keyboard
#     autologins wyli, then `nmcli device wifi connect <SSID>` for wifi-only spots
#   • ssh key-only, the wylited key baked in (wyli + root)
#   • passwordless sudo for wyli (headless bring-up tradeoff — tighten with a
#     sops'd password hash when plan 03's sops-nix lands)
#   • tailscale: `sudo tailscale up` interactively after ssh (authKeyFile
#     reappears with sops)
#   • external disk for storage-transfer work: DEFERRED by decision (2026-10-11)
#     — attach later as a plain mount + whatever service needs it
{ config, pkgs, inputs, ... }:

{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
    ./hardware-configuration.nix
    ../../modules/dns.nix       # plan 12 §1 — AGH tailnet resolver (host MOVED here 2026-10-16)
    ../../modules/caldav.nix    # plan 12 §3 — radicale (host MOVED here 2026-10-16)
  ];

  # TLS = tailscale cert (path B, 2026-10-16): real LE cert for
  # artificer-nixos.story-tiaki.ts.net — NO Cloudflare token on this box, no
  # public exposure, valid on the tailnet. Single vhost, radicale at the root
  # so CalDAV/CardDAV discovery just works. AGH admin stays on :3000 (plain,
  # tailnet-encrypted transport anyway). ingress.nix returns when the CF token
  # lands and dav.wyli.tech names are wanted.
  services.caddy = {
    enable = true;
    virtualHosts."artificer-nixos.story-tiaki.ts.net" = {
      extraConfig = ''
        tls /var/lib/ts-certs/cert.pem /var/lib/ts-certs/key.pem
        reverse_proxy 127.0.0.1:5232
      '';
    };
  };
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 443 ];

  # tailscaled keeps the cert valid internally; this refetches the FILES daily
  # and lets caddy see renewals. (tailscale cert no-ops when still valid.)
  systemd.services.ts-cert-renew = {
    description = "refetch tailscale cert files for caddy";
    after = [ "network-online.target" ];
    before = [ "caddy.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/ts-certs";
      UMask = "0022";
    };
    script = ''
      ${pkgs.tailscale}/bin/tailscale cert \
        --cert-file cert.pem --key-file key.pem artificer-nixos.story-tiaki.ts.net
      chgrp caddy cert.pem key.pem
      chmod 644 cert.pem
      chmod 640 key.pem
      # --no-block: a synchronous reload here deadlocks (caddy start waits on
      # this unit via before=; PID1 serializes). Enqueue and move on.
      systemctl --no-block reload caddy || true
    '';
  };
  systemd.timers.ts-cert-renew = {
    timerConfig = { OnCalendar = "daily"; Persistent = true; };
    wantedBy = [ "timers.target" ];
  };

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
    # first boot: ssh in, `sudo tailscale up`, done. authKeyFile returns when
    # this host joins sops-nix (plan 03) — same pattern as warden.
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
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
  # Tighten (hashedPasswordFile via sops) when plan 03 lands on this host.
  security.sudo.wheelNeedsPassword = false;

  programs.fish.enable = true;

  environment.systemPackages = with pkgs; [
    libraspberrypi   # raspinfo, vcgencmd etc.
  ];

  system.stateVersion = "26.05";
}
