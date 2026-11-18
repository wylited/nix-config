# modules/pi-backup.nix — nightly restic of the pi's irreplaceable state to
# warden over the tailnet (the "not backed up anywhere" gap).
#
# Scope = only what a rebuild cannot regenerate:
#   /var/lib/<svc>         whatever state the pi actually grows
#   /etc/nix               nix.conf/registry.json symlinks just tag along
#                          (no secrets left: radicale-htpasswd deleted
#                          2026-11-09, radicale is passwordless)
#
# Backend: restic sftp → wyli@100.68.142.0:/srv/backups/artificer (warden's
# tailnet IP — deliberately not a MagicDNS name, so the backup still works
# when DNS is what's broken; that's the failure this guards). The target sits
# on warden's disk but is NOT snapshotted (/srv is a nested subvolume), so this
# buys one copy, not one copy on different hardware. Restic-over-tailnet =
# encrypted + authenticated transport for free, no port opening either side.
#
# DRAFT — enable is OFF until the two TODO files exist on the pi; enabling
# early just makes the timer fail loudly (missing key/password). Bring-up:
#   1. on the pi:  umask 077; head -c 32 /dev/urandom | base64 \
#                    > /etc/nix/restic-password
#                  AND store an out-of-band copy (password manager): a password
#                  that only lives inside the repo it opens restores nothing —
#                  same rule as the matrix backup.
#   2. on the pi:  ssh-keygen -t ed25519 -N "" -f /etc/nix/pi-backup_ed25519 \
#                    -C "pi-backup@artificer"
#   3. on warden:  append the .pub to users.users.wyli.openssh.authorizedKeys
#                  with `restrict` — sketch sits next to the tmpfiles rule in
#                  hosts/warden/default.nix.
#   4. flip services.piBackup.enable, rebuild, then once:
#                  systemctl start restic-backups-pi.service
#                  (initialize=true runs `restic init` on first connect)
#   5. verify:     on warden, with the same password file:
#                    restic -r /srv/backups/artificer snapshots
#                  then do one real test restore — a backup that has never
#                  been restored is a hypothesis, not a backup.
#
# Services keep running during the snapshot: radicale is append-only files
# and AGH's irreplaceable yaml is written atomically, so a live copy risks at
# worst a torn sqlite querylog — not worth dropping tailnet DNS for.
{ config, lib, ... }:

{
  options.services.piBackup.enable =
    lib.mkEnableOption "nightly restic of radicale/AGH/secrets to warden (sftp over the tailnet)";

  config = lib.mkIf config.services.piBackup.enable {
    services.restic.backups.pi = {
      initialize = true;
      repository = "sftp:wyli@100.68.142.0:/srv/backups/artificer";
      passwordFile = "/etc/nix/restic-password";

      paths = [
        "/var/lib/radicale"
        "/var/lib/AdGuardHome"
        "/etc/nix"
      ];

      # Repo opener must stay out of the repo it opens (matrix rule):
      # password + the ssh private key are excluded here.
      exclude = [
        "/etc/nix/restic-password"
        "/etc/nix/pi-backup_ed25519"
      ];

      # sftp backend rides an explicit ssh command (key, tailnet IP, sftp
      # subsystem only); accept-new because the host key can't be pre-seeded
      # before first connect. The unit already puts ssh on PATH.
      extraOptions = [
        "sftp.command='ssh -i /etc/nix/pi-backup_ed25519 -o StrictHostKeyChecking=accept-new wyli@100.68.142.0 -s sftp'"
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
        OnCalendar = "02:15"; # early slot; warden has no restic — its immich pg dump is 03:15
        Persistent = true;    # catch up after downtime instead of skipping
        RandomizedDelaySec = "15min";
      };
    };
  };
}
