# Ingress — publish the client API to the tailnet, and nowhere else.
#
# `tailscale serve` terminates TLS with a real Let's Encrypt certificate for the
# node's MagicDNS name and proxies to loopback, so:
#   * clients get a trusted https:// URL (Element refuses self-signed certs),
#   * no domain has to be registered and no certificate has to be wired,
#   * nothing is exposed to the public internet — federation cannot reach us,
#     which is exactly the intent of a private Beeper replacement.
# The mapping lives in tailscaled's own state (`--bg`), so it survives reboots
# and tailscale upgrades; this unit is only there to make it declarative and to
# re-assert it after a rebuild.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.matrixStack;
  proxyTarget = "http://${cfg.listenAddress}:${toString cfg.listenPort}";
in
{
  options.services.matrixStack.ingress = {
    tailscaleServe = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Publish `${cfg.clientUrl}` on this node's tailnet name via
          `tailscale serve`. Requires "HTTPS Certificates" to be enabled for the
          tailnet in the Tailscale admin console.
        '';
      };
    };

    funnel = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Additionally expose the same proxy to the public internet with
          `tailscale funnel`. Only needed if you want push notifications from a
          hosted push gateway or federation; it makes the homeserver world
          reachable, so it is off by default.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.ingress.tailscaleServe.enable) {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "services.matrixStack.ingress.tailscaleServe.enable needs services.tailscale.enable.";
      }
      {
        assertion = cfg.serverName == config.networking.hostName
          || lib.hasPrefix "${config.networking.hostName}." cfg.serverName;
        message = ''
          With tailscale serve the certificate name is fixed by the node's
          MagicDNS name, so services.matrixStack.serverName must be
          "${config.networking.hostName}.<tailnet>.ts.net" (`tailscale status
          --json | jq -r .MagicDNSSuffix` gives the suffix).
        '';
      }
    ];

    systemd.services.matrix-tailscale-serve = {
      description = "Publish the Matrix client API on the tailnet (tailscale serve)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "tailscaled.service" "matrix-synapse.service" ];
      after = [ "tailscaled.service" "matrix-synapse.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # First start has to provision the certificate, which can take a few
        # seconds and fail transiently; without this the unit would stay failed
        # and the homeserver would be unreachable from every client.
        Restart = "on-failure";
        RestartSec = "20s";
      };
      script = ''
        set -eu
        ts=${lib.getExe pkgs.tailscale}

        # tailscaled needs a usable backend before serve can be configured.
        for attempt in $(seq 1 30); do
          if $ts status >/dev/null 2>&1; then break; fi
          if [ "$attempt" = 30 ]; then
            echo "tailscaled was not ready after 60s" >&2
            exit 1
          fi
          sleep 2
        done

        ${if cfg.ingress.funnel.enable then ''
          $ts funnel --bg --https=443 ${proxyTarget}
        '' else ''
          $ts serve --bg --https=443 ${proxyTarget}
        ''}

        # Assert the mapping is really there. A silent no-op here would leave a
        # healthy-looking stack that no client can reach.
        if ! $ts serve status | ${lib.getExe' pkgs.gnugrep "grep"} -q 'https://${cfg.serverName}'; then
          echo "no tailscale serve mapping for ${cfg.serverName} is active" >&2
          $ts serve status >&2
          exit 1
        fi
        $ts serve status
      '';
      # Re-assert the mapping whenever the proxy target changes.
      restartTriggers = [ proxyTarget ];
    };
  };
}
