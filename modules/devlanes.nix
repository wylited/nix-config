# modules/devlanes.nix — plan 12 §4 lane A: shared dev deps for work projects.
#
# One PostgreSQL cluster, databases owned by `wyli` (peer auth — no
# passwords, same convention as plan 10 §5.2). Redis: warden already runs a
# loopback instance on :6379 (hosts/warden/default.nix) — lanes reuse it.
# Mongo stays in docker inside each project's compose (plan 02's call).
#
# HARD RULE (user, 2026-10-11): exactly ONE lane live at a time — enforced by
# scripts/deploy.sh (stops the previous lane before starting the next), and
# the 4 GB slice here is the hard ceiling for any lane-native services.
{ config, lib, pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    # Runs once at cluster init, in order — roles before databases.
    # (ensureUsers/ensureDatabases run every start and can't express
    # "wyli owns two databases" cleanly; this is the boring version.)
    initialScript = pkgs.writeText "dev-lanes-init.sql" ''
      CREATE ROLE wyli WITH LOGIN;
      CREATE DATABASE ms_dev OWNER wyli;
      CREATE DATABASE procurement OWNER wyli;
    '';
    settings.shared_buffers = "256MB";   # lane-sized, not production-sized
  };

  # hard ceiling for the one active lane's native services (PLAN §11)
  systemd.slices."dev-lane" = {
    sliceConfig = {
      MemoryHigh = "3G";
      MemoryMax = "4G";
    };
  };

  environment.systemPackages = with pkgs; [
    postgresql  # psql for lane debugging
  ];
}
