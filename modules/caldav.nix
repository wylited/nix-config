# modules/caldav.nix — plan 12 §3: Radicale = CalDAV + CardDAV source of truth.
#
# Plain files under /var/lib/radicale (restic + snapper cover it). Clients
# (Apple Calendar/Contacts, DAVx5, Thunderbird) talk to dav.ts.wyli.tech
# directly; the vibecoded UI (wycal, cal.ts.wyli.tech, separate project) is
# just another CalDAV client — if the UI rots, calendars don't.
#
# Passwordless since 2026-11-09 (auth.type = "none"): dav.ts.wyli.tech is
# tailnet-only, so the tailnet is the auth boundary. Radicale still 401s
# requests without an Authorization header; clients keep sending their saved
# credentials and any user/password pair is accepted with owner rights on
# that username. The old apr1 hash file (/etc/nix/radicale-htpasswd) is dead
# — delete it from the host on next deploy.
{ config, lib, pkgs, ... }:
{
  services.radicale = {
    enable = true;
    settings = {
      server.hosts = [ "127.0.0.1:5232" ];
      auth.type = "none";
      storage.filesystem_folder = "/var/lib/radicale/collections";
      # rights default = owner_only — single user, nothing to relax
    };
  };
}
