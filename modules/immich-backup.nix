# modules/immich-backup.nix — nightly restic of warden's immich library + the
# immich postgres dump, closing the "no backup at all for /srv/immich" gap
# (2026-10-26 tuning audit).
#
# ⚠ THE PI CANNOT HOLD THIS LIBRARY — DO NOT ENABLE AS-IS ⚠
# The default target below is the pi's SD card (58 GB, 14% used today), which
# is fine for the dumps but WILL be outgrown by /srv/immich the moment a real
# Google Takeout import lands (tens of GB of originals + thumbnails). Enable
# only after pointing `repository` at a real target (bigger disk on the pi, or
# an offsite/object store). Until then the library's only safety net is
# warden's hourly snapper snapshot of /srv — same box, same disk, not a backup.
#
# Scope = the two things a rebuild cannot regenerate:
#   /srv/immich                    the library (originals/thumbs/encoded)
#   $postgresqlBackup.location/    the immich pg dump (users/albums/DB refs);
#     immich.sql.zstd              dump forced fresh by backupPrepareCommand —
#                                  same idiom as modules/matrix/backup.nix
# NOT included: /var/lib/immich-ml — pure model cache, regenerateable by
# deletion + re-download (immich.nix storage note).
#
# DRAFT — enable is OFF until the bring-up below exists; enabling early just
# makes the timer fail loudly (missing key/password). Bring-up:
#   1. on warden: umask 077; head -c 32 /dev/urandom | base64 \
#                  > /etc/nix/restic-password-immich
#                AND store an out-of-band copy (password manager): a password
#                  that only lives on the machine it backs up restores nothing.
#   2. on warden: ssh-keygen -t ed25519 -N "" \
#                  -f /etc/nix/immich-backup_ed25519 -C "immich-backup@warden"
#   3. on the pi: append the .pub to users.users.wyli.openssh.authorizedKeys
#                  with `restrict` — sketch sits next to the tmpfiles rule in
#                  hosts/artificer/default.nix. (`restrict` keeps sftp working
#                  but blocks exec, so the remote half of the size guard below
#                  then logs its NOTE and skips — by design.)
#   4. pick a real target (see the warning above) if not the pi card, then
#                  flip services.immichBackup.enable, rebuild, and once:
#                    systemctl start restic-backups-immich.service
#                  (initialize=true runs `restic init` on first connect)
#   5. verify:     on the pi, with the same password file:
#                    restic -r /srv/backups/immich snapshots
#                  then do one real test restore — a backup that has never
#                  been restored is a hypothesis, not a backup.
#
# Immich keeps running during the snapshot: the originals are write-once
# upload files and the DB is captured by pg_dump, not file copy.
{ config, lib, pkgs, ... }:

let
  pgCfg = config.services.postgresqlBackup;
  # Same filename mapping as the postgresqlBackup module (immich.nix adds the
  # "immich" database; compression comes from the merged config — matrix's
  # backup sets zstd today, the module default is "none").
  dumpFile = "${pgCfg.location}/immich.sql" + {
    none = "";
    gzip = ".gz";
    zstd = ".zstd";
  }."${pgCfg.compression}";
  sshKey = "/etc/nix/immich-backup_ed25519";
in
{
  options.services.immichBackup.enable =
    lib.mkEnableOption "nightly restic of the immich library + pg dump to the pi over the tailnet (DRAFT: needs a real target — see header)";

  config = lib.mkIf config.services.immichBackup.enable {
    services.restic.backups.immich = {
      initialize = true;
      repository = "sftp:wyli@100.95.249.82:/srv/backups/immich";
      passwordFile = "/etc/nix/restic-password-immich";

      paths = [
        "/srv/immich"
        dumpFile
      ];

      # Fresh dump inside every snapshot (matrix-backup idiom) + size guard:
      # warn when the library outgrows the free space at the target. Warn-only
      # — restic dedup/compression means the raw du number is pessimistic, and
      # the guard must never be the reason a night's backup doesn't happen.
      # The remote df needs exec on the ssh key; if the key is sftp-restricted
      # (recommended, step 3), the guard just logs its NOTE and skips.
      backupPrepareCommand = ''
        systemctl start postgresqlBackup-immich.service
        size=$(du -sb /srv/immich | cut -f1)
        echo "immich-backup: /srv/immich is $size bytes (pre-dedup)"
        free=$(ssh -i ${sshKey} -o BatchMode=yes -o StrictHostKeyChecking=accept-new wyli@100.95.249.82 -- df -B1 --output=avail /srv/backups/immich 2>/dev/null | tail -n1) || true
        if [ -z "$free" ]; then
          echo "immich-backup: NOTE: no free-space reading from the target (key sftp-restricted or down); size guard skipped" >&2
        elif [ "$size" -gt "$free" ]; then
          echo "immich-backup: WARNING: /srv/immich ($size B) exceeds free space at the target ($free B) — it will fill the card; move to a real target" >&2
        fi
      '';

      # sftp backend rides an explicit ssh command (key, tailnet IP, sftp
      # subsystem only); accept-new because the host key can't be pre-seeded
      # before first connect. The unit already puts ssh on PATH.
      extraOptions = [
        "sftp.command='ssh -i ${sshKey} -o StrictHostKeyChecking=accept-new wyli@100.95.249.82 -s sftp'"
      ];

      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-monthly 12"
      ];
      checkOpts = [ "--read-data-subset=5%" ];
      # A power loss mid-prune can leave a stale lock; retry, don't die until
      # an operator runs `restic unlock`.
      extraBackupArgs = [ "--retry-lock 10m" ];

      timerConfig = {
        OnCalendar = "04:15"; # after matrix's 03:30 run — no IO/bandwidth overlap
        Persistent = true;    # warden sleeps at night; catch up on wake
        RandomizedDelaySec = "15min";
      };
    };

    # du/df/cut/tail in backupPrepareCommand (systemctl is always on PATH).
    systemd.services.restic-backups-immich.path = [ pkgs.coreutils ];
  };
}
