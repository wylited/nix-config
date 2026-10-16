# modules/dns.nix — plan 12 §1: AdGuard Home as the tailnet split-DNS resolver.
# HOST: artificer-nixos (the rpi5 — small always-on box; DNS shouldn't depend
# on warden being up). Tailscale admin → DNS → nameserver = an's tailnet IP,
# RESTRICTED to wyli.tech (one-time console step, PLAN.md §1 — not settable
# from here). The pi itself must never accept Tailscale DNS (loop): AGH's
# upstreams below are public DoH resolvers, and resolv.conf stays untouched.
#
# Filtering is OFF by decision (2026-10-16): this is a resolver + rewrites
# box, not an ad-blocker — flip filtering_enabled back for the blocklists.
#
# Rewrites point at real tailnet IPs where devices have joined; PLACEHOLDER
# 100.64.0.1 marks names whose host isn't on the tailnet yet (warden is
# offline in the tailnet as of 2026-10-16 — fix when warden rejoins).
# mutableSettings=true means the UI owns /var/lib/adguardhome/AdGuardHome.yaml
# after first boot — edits here only apply on a fresh state dir.
{ config, lib, pkgs, ... }:
{
  services.adguardhome = {
    enable = true;
    port = 3000;                    # admin UI — dns.wyli.tech via caddy (ingress.nix)
    mutableSettings = true;
    openFirewall = false;           # tailnet interface rules below; loopback implicit
    settings = {
      http = { address = "0.0.0.0:3000"; };
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        bind_port = 53;
        bootstrap_dns = [ "9.9.9.9" "1.1.1.1" ];
        upstream_dns = [
          "https://dns.quad9.net/dns-query"
          "https://cloudflare-dns.com/dns-query"
        ];
        protection_enabled = false; # resolver + cache only (2026-10-16 decision)
        filtering_enabled = false;  # ad-block lists are an opt-in bonus later
        cache_size = 67108864;      # 64 MiB
      };
      filtering.rewrites = [
        # --- services (full words); dav/cal/dns live on an (pi) ---
        { domain = "immich.wyli.tech"; answer = "100.64.0.1"; }        # warden (placeholder — warden off tailnet)
        { domain = "dav.wyli.tech";    answer = "100.95.249.82"; }     # an — radicale
        { domain = "cal.wyli.tech";    answer = "100.95.249.82"; }     # an — wycal UI (future)
        { domain = "stt.wyli.tech";    answer = "100.64.0.1"; }        # warden (placeholder)
        { domain = "matrix.wyli.tech"; answer = "100.64.0.1"; }        # warden (placeholder)
        { domain = "dns.wyli.tech";    answer = "100.95.249.82"; }     # an — AGH admin
        { domain = "ms.dev.wyli.tech"; answer = "100.64.0.1"; }        # warden (placeholder)
        # --- machines (fleet short forms, PLAN.md §0.1) ---
        { domain = "wa.wyli.tech"; answer = "100.64.0.1"; }            # warden (placeholder — off tailnet)
        { domain = "sd.wyli.tech"; answer = "100.84.47.44"; }          # scout-darwin
        { domain = "sa.wyli.tech"; answer = "100.64.0.2"; }            # scout-asahi (not joined yet)
        { domain = "rg.wyli.tech"; answer = "100.127.195.50"; }        # rogue-glyph
        { domain = "an.wyli.tech"; answer = "100.95.249.82"; }         # artificer-nixos (rpi5, this host)
      ];
    };
  };

  # DNS + admin reachable from the tailnet only
  networking.firewall.interfaces."tailscale0" = {
    allowedTCPPorts = [ 53 3000 ];
    allowedUDPPorts = [ 53 ];
  };
}
