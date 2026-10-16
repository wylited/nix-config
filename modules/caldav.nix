# modules/caldav.nix — plan 12 §3: Radicale = CalDAV + CardDAV source of truth.
#
# Plain files under /var/lib/radicale (restic + snapper cover it). Clients
# (Apple Calendar/Contacts, DAVx5, Thunderbird) talk to dav.wyli.tech
# directly; the vibecoded UI (cal.wyli.tech, separate project, PLAN §3 v0/v1)
# is just another CalDAV client — if the UI rots, calendars don't.
#
# First-boot: create the credential —
#   htpasswd -B /etc/nix/radicale-htpasswd wyli && chmod 640 /etc/nix/radicale-htpasswd
# (sops-nix owns this file after the plan 03 migration)
{ config, lib, pkgs, ... }:
{
  services.radicale = {
    enable = true;
    settings = {
      server.hosts = [ "127.0.0.1:5232" ];
      auth = {
        type = "htpasswd";
        htpasswd_filename = "/etc/nix/radicale-htpasswd";
        # "md5" = bare hex md5 (radicale core, no passlib). nixpkgs' radicale
        # doesn't ship passlib, so bcrypt/autodetect would fail at auth time.
        # Acceptable: TLS terminates at caddy, file is root:radicale 0640.
        htpasswd_encryption = "md5";
      };
      storage.filesystem_folder = "/var/lib/radicale/collections";
      # rights default = owner_only — single user, nothing to relax
    };
  };

  # radicale reads the htpasswd file as its own user — after creating it:
  #   chgrp radicale /etc/nix/radicale-htpasswd && chmod 640 /etc/nix/radicale-htpasswd
}
