# modules/dashboard.nix — dash.ts.wyli.tech: one static page (dash/ at the repo
# root, served straight from the store) plus a same-origin /caldav/* proxy to
# radicale, so the page can read the calendar without CORS or stored secrets.
# No daemon, no port, no build step: caddy is already the front door.
{ config, lib, ... }:
let
  # Same guard as modules/ingress.nix: without the DNS-01 token caddy cannot
  # issue a cert, so only serve when a token or a live cert is on the host.
  canServe =
    builtins.pathExists "/etc/nix/acme-desec-env"
    || builtins.pathExists "/var/lib/acme/ts.wyli.tech/fullchain.pem";
in
{
  options.wyli.dashboard.enable = lib.mkEnableOption "the dash.ts.wyli.tech dashboard";

  config = lib.mkIf config.wyli.dashboard.enable {
    services.caddy.virtualHosts = lib.mkIf canServe {
      "https://dash.ts.wyli.tech" = {
        useACMEHost = "ts.wyli.tech";
        extraConfig = ''
          # radicale is loopback :5232 and passwordless (modules/caldav.nix);
          # the proxy exists to keep the page same-origin, not to add auth.
          handle_path /caldav/* {
            reverse_proxy 127.0.0.1:5232
          }
          handle {
            root * ${../dash}
            file_server
            encode zstd gzip
          }
          # no matcher: `/` is an exact-path match in caddy, so it only ever
          # applied to index.html. These belong on every asset.
          header Cache-Control "no-store"
          header X-Content-Type-Options "nosniff"
        '';
      };
    };
  };
}
