# modules/dns.nix — plan 12 §1: AdGuard Home as the tailnet split-DNS resolver.
# Tailscale admin → DNS → nameserver = warden's tailnet IP, RESTRICTED to
# wyli.tech (one-time console step, documented in PLAN.md §1 — not settable
# from here). Warden itself must never accept Tailscale DNS (loop): AGH's
# upstreams below are public DoH resolvers, and resolv.conf stays untouched.
#
# First-boot: rewrites below point every name at the PLACEHOLDER 100.64.0.1
# (valid CGNAT address, deliberately not a real device) — replace with the
# output of `tailscale ip -4` per device, then treat the UI as the owner of
# /var/lib/adguardhome/AdGuardHome.yaml (mutableSettings).
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
        protection_enabled = true;
        filtering_enabled = true;   # ad-block lists are an opt-in bonus later
        cache_size = 67108864;      # 64 MiB
      };
      filtering.rewrites = [
        # --- services (full words; all hosted on warden) ---
        { domain = "immich.wyli.tech"; answer = "100.64.0.1"; }
        { domain = "dav.wyli.tech";    answer = "100.64.0.1"; }
        { domain = "cal.wyli.tech";    answer = "100.64.0.1"; }
        { domain = "stt.wyli.tech";    answer = "100.64.0.1"; }
        { domain = "matrix.wyli.tech"; answer = "100.64.0.1"; }
        { domain = "dns.wyli.tech";    answer = "100.64.0.1"; }
        { domain = "ms.dev.wyli.tech"; answer = "100.64.0.1"; }
        # --- machines (fleet short forms, PLAN.md §0.1) ---
        { domain = "wa.wyli.tech"; answer = "100.64.0.1"; }            # warden
        { domain = "sd.wyli.tech"; answer = "100.64.0.2"; }            # scout-darwin
        { domain = "sa.wyli.tech"; answer = "100.64.0.3"; }            # scout-asahi
        { domain = "rg.wyli.tech"; answer = "100.64.0.4"; }            # rogue-glyph
        { domain = "an.wyli.tech"; answer = "100.64.0.5"; }            # artificer-nixos (rpi5, when it joins)
      ];
    };
  };

  # DNS + admin reachable from the tailnet only
  networking.firewall.interfaces."tailscale0" = {
    allowedTCPPorts = [ 53 3000 ];
    allowedUDPPorts = [ 53 ];
  };
}
