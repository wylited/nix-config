# modules/sure.nix — Sure personal finance (we-promise/sure, the Maybe
# community fork) as a declarative docker-compose stack.
#
# Design: config-as-code around the vendor's compose stack. The compose file
# is VENDORED in this repo (./compose.yml, five "warden edit" markers) so
# upgrades are visible git diffs and a rebuild recreates changed containers.
# Secrets live ONLY in /var/lib/sure/sure.env (root 0600, guard pattern like
# /etc/nix/acme-desec-env) — never in the nix store (world-readable) or git.
#
# Lifecycle: oneshot unit running `compose up --wait` (RemainAfterExit), so
# `systemctl status sure` reflects a healthy stack and a failed boot is a
# FAILED UNIT, not a half-up stack. depends_on: service_healthy semantics are
# compose's job (db/redis healthchecks live in the vendored file), which is
# why this is not per-container oci-containers declarations.
#   stop  = full `compose down` (maintenance semantics)
#   start = bring stack up and wait for health
#
# Upgrades: bump services.sure.imageTag (pin a real version — "stable"
# floats on every start), rebuild; --pull always fetches, migrations run on
# boot. Rollback = revert + rebuild; a schema migration moved forward means
# restoring the backup service's dump instead (db downgrades unsupported).
#
# Ingress: caddy fronts web on 127.0.0.1:${port} — declare the vhost via
# wyli.ingress.routes (hosts/warden), not here; this module stays host-agnostic.
#
# sure.env template (create once by hand, chmod 600; values via
# `openssl rand -hex 64|32`, token via `openssl rand -base64 32`):
#   SECRET_KEY_BASE=...        # WRITE-ONCE — rotating it makes encrypted
#                              # columns unreadable (docs/hosting/docker.md)
#   POSTGRES_PASSWORD=...
#   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=...
#   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=...
#   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=...
#   MCP_API_TOKEN=...          # /mcp bearer — full read/write; treat as a password
#   MCP_USER_EMAIL=...         # must match the registered Sure user
{ config, lib, pkgs, ... }:

let
  cfg = config.services.sure;
  composeFile = pkgs.writeText "sure-compose.yml" (lib.fileContents ./compose.yml);
  # one line: a multi-line string here lands verbatim in the unit's
  # ExecStart/ExecStop and systemd rejects the wrapped lines
  compose =
    "${pkgs.docker-compose}/bin/docker-compose --env-file ${cfg.stateDir}/sure.env -f ${composeFile}";
in
{
  options.services.sure = {
    enable = lib.mkEnableOption "Sure personal finance (docker compose behind caddy)";
    imageTag = lib.mkOption {
      type = lib.types.str;
      default = "stable";
      description = "ghcr.io/we-promise/sure tag. Pin (e.g. \"0.7.6\") for reproducible upgrades.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "loopback port caddy proxies to";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sure";
      description = "bind-mount root: pg/, storage/, backups/, sure.env, compose.yml";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.sure = {
      description = "Sure — personal finance (docker compose)";
      after = [ "docker.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [ pkgs.docker pkgs.docker-compose ];

      # Unit env feeds compose ${...} interpolation; process env BEATS
      # --env-file, so these win over anything stray in sure.env.
      environment = {
        COMPOSE_PROJECT_NAME = "sure";
        SURE_IMAGE_TAG = cfg.imageTag;
        PORT = toString cfg.port;
        SURE_STATE_DIR = cfg.stateDir;
        BACKUP_DIR = "${cfg.stateDir}/backups";
      };

      preStart = ''
        install -d -m 700 ${cfg.stateDir} ${cfg.stateDir}/pg ${cfg.stateDir}/storage ${cfg.stateDir}/backups
        # persistent config copy the backup service archives (restore.sh
        # expects config/compose.yml + config/.env inside every backup)
        install -m 600 ${composeFile} ${cfg.stateDir}/compose.yml
        if [ ! -s ${cfg.stateDir}/sure.env ]; then
          echo "sure: create ${cfg.stateDir}/sure.env first (template in modules/sure.nix header)" >&2
          exit 1
        fi
        chmod 600 ${cfg.stateDir}/sure.env
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = cfg.stateDir;
        TimeoutStartSec = "15min";   # first boot: image pull + migrations
        ExecStart = "${compose} --profile backup up -d --wait --pull always";
        ExecStop = "${compose} down";
      };
    };
  };
}
