# Backups — three restore paths, in increasing order of effort.
#
# 0. warden's `services.snapper` root config takes an hourly btrfs snapshot of
#    `/`, which already contains `/var/lib/matrix-*` (plan 08). That is the
#    instant, zero-cost "undo the last hour" path — nothing to configure here,
#    but it is why an obvious mistake is never a disaster.
# 1. `pg_dump` per database, nightly, into /var/backup/postgresql. This is the
#    authoritative restore path: it rebuilds Synapse's rooms and every bridge's
#    message/session tables from SQL, no PostgreSQL version or file layout
#    assumptions involved.
# 2. restic snapshot of the dump directory plus every state directory (appservice
#    tokens, registration files, and the bridges' pickle/device state, which is
#    what makes a restored bridge keep its linked devices instead of needing a
#    re-pair).
#
# Both run on a timer with `Persistent = true`: warden is a laptop and is
# routinely asleep at 02:30/03:30, so the runs must catch up on wake rather than
# be skipped. `backupPrepareCommand` forces a fresh dump inside every snapshot,
# so a restic snapshot is always self-consistent.
#
# The repository is a local path. When the distributed backup plan lands, change
# `services.matrixStack.backup.repository` to the remote URL and add its
# credentials — nothing else in this file moves.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.matrixStack;
  dumpLocation = cfg.backup.dumpDirectory;
in
{
  config = lib.mkIf (cfg.enable && cfg.backup.enable) {
    services.postgresqlBackup = {
      enable = true;
      startAt = cfg.backup.startAt;
      databases = cfg.databases;
      location = dumpLocation;
      compression = "zstd";
      compressionLevel = 9;
      # `-C` (the default) makes the dump self-contained; `--clean --if-exists`
      # makes it restorable over an existing database, which is what the exact
      # restore procedure in the plan doc relies on:
      #   zstd -dc dump.sql.zst | sudo -u postgres psql -d postgres
      pgdumpOptions = "-C --clean --if-exists";
    };

    # `startAt` only sets OnCalendar on the per-database timers.
    systemd.timers = lib.genAttrs (map (db: "postgresqlBackup-${db}") cfg.databases) (_: {
      timerConfig.Persistent = true;
    });

    services.restic.backups.matrix = {
      initialize = true;
      repository = cfg.backup.repository;
      passwordFile = "${cfg.secrets.directory}/restic-password";

      paths = cfg.stateDirectories ++ [
        cfg.secrets.directory
        dumpLocation
      ];

      # The repository password must not live inside the repository it opens:
      # keep an out-of-band copy (plan doc, restore drill).
      exclude = [ "${cfg.secrets.directory}/restic-password" ];

      backupPrepareCommand = lib.concatMapStringsSep "\n" (db: "systemctl start postgresqlBackup-${db}.service") cfg.databases;
      pruneOpts = cfg.backup.pruneOpts;
      checkOpts = [ "--read-data-subset=5%" ];
      # A power loss during a prune can leave a stale lock behind; retry instead
      # of failing until an operator runs `restic unlock`.
      extraBackupArgs = [ "--retry-lock" "10m" ];

      timerConfig = {
        OnCalendar = "03:30";
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    };

    # restic reads the password file that matrix-secrets generates.
    systemd.services.restic-backups-matrix = {
      wants = [ "matrix-secrets.service" ];
      after = [ "matrix-secrets.service" ];
      # Surface a failed backup immediately instead of at the next 5-minute tick.
      unitConfig.OnFailure = lib.optional cfg.watchdog.enable "matrix-healthcheck.service";
    };

    # Take a snapshot right before an unattended upgrade: it is the fastest way
    # back if a new bridge version misbehaves at 03:00. A failed snapshot blocks
    # the upgrade on purpose.
    systemd.services.nixos-upgrade = {
      preStart = "systemctl start restic-backups-matrix.service";
      unitConfig.OnFailure = lib.optional cfg.watchdog.enable "matrix-healthcheck.service";
    };
  };
}
