# Health watchdog.
#
# `Restart=always` covers crashes. This covers the quiet failures: a unit that
# is not running, a bridge that is up but no longer connected to the homeserver,
# Synapse that answers HTTP but cannot use its database, a backup that silently
# stopped happening, and a failed unattended upgrade. One script, one timer, and
# an alert into a Matrix room when the set of problems changes.
#
# Alerting is best-effort by construction — the alert goes through the very
# homeserver being watched — so delivery failures are reported on stderr and
# never suppress the next alert.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.matrixStack;
  inherit (cfg) bridges;

  matrixUrl = "http://${cfg.listenAddress}:${toString cfg.listenPort}";
  resticRepo = cfg.backup.repository;
  resticPasswordFile = "${cfg.secrets.directory}/restic-password";

  # Units that must be running, plus one HTTP probe per enabled bridge.
  requiredUnits = [ "postgresql.service" "matrix-synapse.service" ]
    ++ lib.optional bridges.whatsapp.enable "mautrix-whatsapp.service"
    ++ lib.optionals bridges.instagram.enable [ "mautrix-instagram-registration.service" "mautrix-instagram.service" ]
    ++ lib.optionals bridges.discord.enable [ "mautrix-discord-registration.service" "mautrix-discord.service" ];

  bridgeProbes = lib.optional bridges.whatsapp.enable {
    name = "mautrix-whatsapp";
    port = bridges.whatsapp.appservicePort;
  } ++ lib.optional bridges.instagram.enable {
    name = "mautrix-instagram";
    port = bridges.instagram.appservicePort;
  } ++ lib.optional bridges.discord.enable {
    name = "mautrix-discord";
    port = bridges.discord.appservicePort;
  };

  # A backup that stops happening is only visible if something looks at the
  # backup, so the timer doubles as a freshness check.
  backupEnabled = cfg.backup.enable;

  # Postgres and the media store live on the same filesystem; below this the
  # design expects writes to start failing, which no other probe would notice
  # (a `select 1` still succeeds on a full filesystem).
  minFreeKb = 10 * 1024 * 1024; # 10 GiB

  healthcheck = ''
    set -u
    problems=""

    check_unit() {
      systemctl is-active --quiet "$1" || problems="$problems $1(inactive)"
    }

    check_failed() {
      systemctl is-failed --quiet "$1" && problems="$problems $1(failed)"
    }

    check_disk() {
      available_kb=$(${lib.getExe' pkgs.coreutils "df"} -Pk /var/lib | ${lib.getExe' pkgs.gawk "awk"} 'NR==2 {print $4}')
      if [ "$available_kb" -lt ${toString minFreeKb} ]; then
        problems="$problems disk(avail:$(( available_kb / 1024 / 1024 ))GiB)"
      fi
    }

    check_matrix() {
      code=$(${lib.getExe pkgs.curl} -s -o /dev/null -w '%{http_code}' \
        --max-time 5 '${matrixUrl}/health' || echo 000)
      case "$code" in
        2??) ;;
        *) problems="$problems synapse(http:$code)" ;;
      esac
    }

    # /health is Synapse's *liveness* endpoint and does not touch the database,
    # so a homeserver whose pool is poisoned still answers 200. Ask the DB
    # directly, as the service user, over the same socket peer auth uses.
    check_synapse_db() {
      if ! runuser -u matrix-synapse -- ${lib.getExe' pkgs.postgresql "psql"} \
             -h /run/postgresql -d matrix-synapse -tAc 'select 1' >/dev/null 2>&1; then
        problems="$problems synapse(db)"
      fi
    }

    # mautrix serves these on the appservice listener without auth:
    #   /_matrix/mau/live  -> 200 once the HTTP server is up
    #   /_matrix/mau/ready -> 500 until the bridge is connected to the homeserver
    # 404 means the running version predates the endpoint, which is not a fault.
    check_bridge() {
      name=$1
      port=$2
      for path in live ready; do
        code=$(${lib.getExe pkgs.curl} -s -o /dev/null -w '%{http_code}' \
          --max-time 5 "http://${cfg.listenAddress}:$port/_matrix/mau/$path" || echo 000)
        case "$code" in
          2??) ;;
          404) ;;
          *) problems="$problems $name($path:$code)" ;;
        esac
      done
    }

    ${lib.optionalString backupEnabled ''
      # Freshness of both backup paths. Restores are worthless if the last
      # snapshot is a week old.
      newest_dump=$(${lib.getExe' pkgs.findutils "find"} ${cfg.backup.dumpDirectory} \
        -name '*.sql.zst' -newermt '-26 hours' -print -quit 2>/dev/null || true)
      [ -n "$newest_dump" ] || problems="$problems postgres-dump(stale)"

      if [ -r ${resticPasswordFile} ]; then
        latest=$(${lib.getExe pkgs.restic} snapshots --no-lock --latest 1 --json 2>/dev/null \
          | ${lib.getExe pkgs.jq} -r '.[0].time // empty' || true)
        if [ -z "$latest" ]; then
          problems="$problems restic(no-snapshot)"
        else
          age=$(( $(${lib.getExe' pkgs.coreutils "date"} +%s) - $(${lib.getExe' pkgs.coreutils "date"} -d "$latest" +%s) ))
          [ "$age" -lt 129600 ] || problems="$problems restic(stale:$(( age / 3600 ))h)"
        fi
      else
        problems="$problems restic(no-password-file)"
      fi
    ''}

    ${lib.concatMapStringsSep "\n" (unit: ''check_unit ${unit}'') requiredUnits}
    check_disk
    check_matrix
    check_synapse_db
    ${lib.concatMapStringsSep "\n" (p: ''check_bridge ${p.name} ${toString p.port}'') bridgeProbes}
    ${lib.optionalString backupEnabled ''
      check_failed restic-backups-matrix.service
      check_failed nixos-upgrade.service
    ''}

    ${lib.optionalString (cfg.watchdog.alertRoom != null) ''
      # Alerting needs a token; if it is missing, say so instead of silently
      # dropping every alert.
      [ -r "${cfg.watchdog.alertTokenFile}" ] || problems="$problems alert-token(missing)"

      # Alerts that could not be delivered are themselves a problem worth
      # reporting — otherwise a revoked token looks exactly like a healthy
      # system that simply never has anything to say.
      alert_failures_file=/run/matrix-healthcheck-alert-failures
      alert_failures=$(cat "$alert_failures_file" 2>/dev/null || echo 0)
      [ "$alert_failures" -gt 0 ] && problems="$problems alert-delivery(failed:$alert_failures)"
    ''}

    if [ -z "$problems" ]; then
      echo "matrix-healthcheck: ok"
      exit 0
    fi

    echo "matrix-healthcheck: degraded:$problems"

    ${lib.optionalString (cfg.watchdog.alertRoom != null) ''
      token_file="${cfg.watchdog.alertTokenFile}"
      state_file=/run/matrix-healthcheck.state
      previous=$(cat "$state_file" 2>/dev/null || echo "")

      if [ "$problems" != "$previous" ] && [ -r "$token_file" ]; then
        body="matrix-healthcheck: degraded:$problems"
        payload=$(${lib.getExe pkgs.jq} -n --arg b "$body" '{msgtype:"m.text",body:$b}')
        encoded_room=$(printf '%s' "${cfg.watchdog.alertRoom}" | ${lib.getExe' pkgs.gnused "sed"} -e 's/!/%21/g' -e 's/:/%3A/g')
        if ${lib.getExe pkgs.curl} -sf --max-time 10 -X POST \
             -H "Authorization: Bearer $(cat "$token_file")" \
             -H 'Content-Type: application/json' \
             --data "$payload" \
             '${matrixUrl}/_matrix/client/v3/rooms/'"$encoded_room"'/send/m.room.message/'$(date +%s); then
          # Only a *delivered* alert suppresses the next one; a failed POST (the
          # usual case when Synapse itself is the problem, or a revoked token)
          # must retry and must be visible.
          printf '%s' "$problems" > "$state_file" 2>/dev/null || true
          echo 0 > "$alert_failures_file" 2>/dev/null || true
          echo "matrix-healthcheck: alert delivered to ${cfg.watchdog.alertRoom}"
        else
          echo $(( alert_failures + 1 )) > "$alert_failures_file" 2>/dev/null || true
          echo "matrix-healthcheck: alert delivery failed (''${alert_failures} before), will retry next tick" >&2
        fi
      fi
    ''}
    exit 1
  '';
in
{
  config = lib.mkIf (cfg.enable && cfg.watchdog.enable) {
    systemd.services.matrix-healthcheck = {
      description = "Matrix stack health check";
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
      };
      # Explicit runtime deps on top of the NixOS default PATH: psql for the
      # database probe, runuser to become matrix-synapse, restic/jq for the
      # snapshot-age check.
      path = [
        pkgs.jq
        pkgs.postgresql
        pkgs.restic
        pkgs.util-linux
      ];
      environment = {
        RESTIC_REPOSITORY = resticRepo;
        RESTIC_PASSWORD_FILE = resticPasswordFile;
      };
      script = healthcheck;
    };

    systemd.timers.matrix-healthcheck = {
      description = "Periodic Matrix stack health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "matrix-healthcheck.service";
        OnBootSec = "10min";
        OnUnitActiveSec = cfg.watchdog.interval;
        # No `Persistent`: that only applies to wall-clock (OnCalendar) timers,
        # and a monotonic timer already resumes counting after suspend.
      };
    };
  };
}
