# modules/ingress.nix — caddy ingress, one path (2026-11-08):
#
# HTTPS : https://<name>.ts.wyli.tech — real LE wildcard via DNS-01 on deSEC.
#         ts.wyli.tech is NS-delegated (CF dashboard, manual) to desec.io, so
#         the API token only ever controls that throwaway subzone. There are
#         NO public wyli.tech service records and none are needed — raw
#         machine names resolve via MagicDNS (warden-arch, artificer-nixos…).
#
# Secret: /etc/nix/acme-desec-env (0600) containing
#   DESEC_TOKEN=<deSEC token, ts.wyli.tech zone only>
# Absent file => caddy gets no vhosts and no cert (guard pattern like
# lab-cache.nix): create it, then `nixos-rebuild switch` again.
{ config, lib, pkgs, ... }:
let
  hasDesecToken = builtins.pathExists "/etc/nix/acme-desec-env";
in
{
  options.wyli.ingress.routes = lib.mkOption {
    type = lib.types.attrsOf (lib.types.either lib.types.port (lib.types.listOf lib.types.port));
    default = { };
    description = "service vhosts terminated by this host's caddy: <name>.ts.wyli.tech → loopback port, or a list of ports for health-checked blue-green upstreams";
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
        # lego's LOCAL propagation check walks NS via the host resolver, which
        # returns subzone-NS in AUTHORITY (not ANSWER) → "could not determine
        # authoritative nameservers" forever. LE validates from its own
        # recursors, which resolve the delegation fine (verified via DoH).
        dnsPropagationCheck = false;
        group = "caddy";                   # caddy user reads the pem files
        reloadServices = [ "caddy" ];
      };
    };

    services.caddy = {
      enable = true;
      # auto_https off: caddy must never self-issue or bind :443 uninvited —
      # TLS sites are explicit https:// addresses below, with our own cert.
      globalConfig = "auto_https off";
      virtualHosts = lib.mkIf hasDesecToken (lib.mapAttrs
        (n: p: {
          useACMEHost = "ts.wyli.tech";
          # A list = blue-green slots: all upstreams in one pool with active
          # health checks, so the app's own flip-between-slots updater never
          # needs a caddy reload. Single int stays a plain reverse_proxy.
          extraConfig =
            if lib.isList p then ''
              reverse_proxy ${lib.concatMapStringsSep " " (pt: "127.0.0.1:${toString pt}") p} {
                health_uri /
                health_interval 5s
                health_timeout 3s
              }''
            else "reverse_proxy 127.0.0.1:${toString p}";
        })
        config.wyli.ingress.routes);
    };

    # DNS-01 needs no inbound 80; caddy only serves :443.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 443 ];
    networking.firewall.interfaces."end0".allowedTCPPorts = [ 443 ];  # LAN-direct
  };
}
