# modules/ingress.nix — caddy ingress, dual-path TLS story (2026-10-26):
#
# HTTP  : http://<name>.wyli.tech — tokenless, tailnet-only, split-DNS/CGNAT
#         A-records on the CF zone. WireGuard already encrypts the transport.
# HTTPS : https://<name>.ts.wyli.tech — real LE wildcard via DNS-01 on deSEC.
#         ts.wyli.tech is NS-delegated (CF dashboard, manual) to desec.io, so
#         the API token only ever controls that throwaway subzone.
#
# Secret: /etc/nix/acme-desec-env (0600) containing
#   DESEC_TOKEN=<deSEC token, ts.wyli.tech zone only>
# Absent file => TLS path no-ops, plain HTTP stays (guard pattern like
# lab-cache.nix): create it, then `nixos-rebuild switch` again.
{ config, lib, pkgs, ... }:
let
  # service hostname → loopback port it terminates for. Per-host: warden keeps
  # the big services' vhosts, artificer (small static box) only dav/cal/dns.
  routesCfg = config.wyli.ingress.routes;
  hasDesecToken = builtins.pathExists "/etc/nix/acme-desec-env";
  # immich.wyli.tech → immich.ts.wyli.tech (TLS twin of every route)
  tsName = n: builtins.replaceStrings [ ".wyli.tech" ] [ ".ts.wyli.tech" ] n;
in
{
  options.wyli.ingress.routes = lib.mkOption {
    type = lib.types.attrsOf lib.types.port;
    default = {
      "immich.wyli.tech" = 2283;   # modules/immich.nix (warden)
      "dav.wyli.tech"    = 5232;   # modules/caldav.nix (radicale)
      "cal.wyli.tech"    = 8423;   # vibecoded CalDAV/CardDAV UI (v0 build, PLAN §3)
      "stt.wyli.tech"    = 8000;   # modules/whisper.nix (speaches, warden)
      "dns.wyli.tech"    = 3000;   # modules/dns.nix (AdGuard Home admin)
    };
    description = "service vhosts terminated by this host's caddy, name → loopback port";
  };
  config = {
    security.acme = lib.mkIf hasDesecToken {
      acceptTerms = true;
      defaults.email = "wyli@wyli.tech";
      certs."ts.wyli.tech" = {
        domain = "ts.wyli.tech";
        extraDomainNames = [ "*.ts.wyli.tech" ];
        dnsProvider = "desec";
        environmentFile = "/etc/nix/acme-desec-env";
        dnsPropagationCheck = true;
        group = "caddy";                   # caddy user reads the pem files
        reloadServices = [ "caddy" ];
      };
    };

    services.caddy = {
      enable = true;
      # auto_https off: caddy must never self-issue or bind :443 uninvited —
      # TLS sites are explicit https:// addresses below, with our own cert.
      globalConfig = "auto_https off";
      virtualHosts =
        let
          plain = lib.mapAttrs' (n: p: lib.nameValuePair "http://${n}" p) routesCfg;
          tls = lib.mapAttrs
            (n: p: {
              useACMEHost = lib.mkIf hasDesecToken "ts.wyli.tech";
              extraConfig = "reverse_proxy 127.0.0.1:${toString p}";
            })
            (lib.genAttrs (builtins.attrNames routesCfg) tsName);
          tlsSites = if hasDesecToken
            then lib.mapAttrs' (n: v: lib.nameValuePair "https://${n}" v) tls
            else { };
        in
        plain // tlsSites;
    };

    networking.firewall.interfaces."tailscale0".allowedTCPPorts =
      [ 80 ] ++ lib.optionals hasDesecToken [ 443 ];
    # LAN-direct only where the TLS stack lives (warden); the pi stays
    # tailnet-only on :80 exactly as before.
    networking.firewall.interfaces."end0".allowedTCPPorts =
      lib.optionals hasDesecToken [ 80 443 ];
  };
}
