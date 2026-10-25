# modules/ingress.nix — plan 12 §0: Caddy behind a real wildcard cert.
#
# ACME wildcard `*.wyli.tech` via DNS-01 (lego + Cloudflare) — no inbound
# ports at all, no tailscale-serve dependency, and the names/certs survive
# any future transport swap. NixOS owns issuance/renewal (security.acme);
# Caddy only consumes the pem files (useACMEHost).
#
# Secret: /etc/nix/acme-cf-token (0600) containing
#   CLOUDFLARE_DNS_API_TOKEN=<token scoped Zone:DNS:Edit on wyli.tech only>
# Absent file => module no-ops (same guard pattern as lab-cache.nix):
# create it, then `nixos-rebuild switch` again to bring ingress up.
{ config, lib, pkgs, ... }:
let
  # service hostname → loopback port it terminates for. Per-host: warden keeps
  # the big services' vhosts, artificer (small static box) only dav/cal/dns.
  routesCfg = config.wyli.ingress.routes;
  hasCfToken = builtins.pathExists "/etc/nix/acme-cf-token";
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
      # matrix.wyli.tech joins here when plan 10 deploys (synapse :8008)
    };
    description = "service vhosts terminated by this host's caddy, name → loopback port";
  };
  # ---- mode 1: no CF token → plain HTTP on :80, tailnet-only ----------------
  # (2026-10-26: the wildcard/DNS-01 path stays parked; WireGuard already
  # encrypts the transport, so bare http://name is fine on the tailnet)
  config = lib.mkIf (!hasCfToken) {
    services.caddy = {
      enable = true;
      virtualHosts = builtins.mapAttrs
        (name: port: {
          # no serverAliases acme — plain http host match
          extraConfig = "reverse_proxy 127.0.0.1:${toString port}";
        })
        routesCfg;
    };
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 80 ];
  };

  # ---- mode 2: CF token present → wildcard TLS via DNS-01 (unchanged) ------
  config = lib.mkIf hasCfToken {
    security.acme = {
      acceptTerms = true;
      defaults.email = "wyli@wyli.tech";   # LE expiry notices — TODO confirm address
      certs."wyli.tech" = {
        domain = "wyli.tech";
        extraDomainNames = [ "*.wyli.tech" ];
        dnsProvider = "cloudflare";
        environmentFile = "/etc/nix/acme-cf-token";
        dnsPropagationCheck = true;
        group = "caddy";                   # caddy user reads the pem files
        reloadServices = [ "caddy" ];
      };
    };

    services.caddy = {
      enable = true;
      virtualHosts = builtins.mapAttrs
        (name: port: {
          useACMEHost = "wyli.tech";
          extraConfig = "reverse_proxy 127.0.0.1:${toString port}";
        })
        routesCfg;
    };

    # tailnet-only TLS; DNS-01 needs no inbound 80/443 from the internet
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 443 ];
  };
}
