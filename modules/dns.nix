# modules/dns.nix — plan 12 §1: AdGuard Home as the tailnet split-DNS resolver.
# HOST: artificer-nixos (the rpi5 — small always-on box; DNS shouldn't depend
# on warden being up). Tailscale admin → DNS → nameserver = an's tailnet IP,
# RESTRICTED to wyli.tech (one-time console step, PLAN.md §1 — not settable
# from here). The pi itself must never accept Tailscale DNS (loop): AGH's
# upstreams below are public DoH resolvers, and resolv.conf stays untouched.
#
# Filtering pipeline is ON but with ZERO blocklists (filters = [], 2026-10-16
# decision): resolver + rewrites + cache, no ad-blocking — rewrites only fire
# when the pipeline runs, which is why filtering_enabled stays true here.
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
      # AGH admin UI login — bcrypt hash (rotate via the UI). Tailnet-only port.
      users = [ {
        name = "wyli";
        password = "$2y$10$1McrnFSyYFM21.p.G6YRReTAS7rpmDuLJFPv3N4ob6x.6HLvysAuG";
      } ];
      # blocklists live at TOP-LEVEL filters:/user_rules: (NOT filtering.filters
      # — that key is inert). Empty = resolver + rewrites, zero ad-blocking.
      filters = [ ];
      user_rules = [ ];
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        bind_port = 53;
        bootstrap_dns = [ "9.9.9.9" "1.1.1.1" ];
        upstream_dns = [
          "https://dns.quad9.net/dns-query"
          "https://cloudflare-dns.com/dns-query"
        ];
        cache_size = 67108864;      # 64 MiB
      };
      # AGH ≥0.107.37 schema: rewrites + the filtering switches live HERE, not
      # under dns: (nested keys are ignored; pipeline defaults ON and the
      # default blocklist ships enabled — rewrites only fire when this pipeline
      # is up). yaml-merge re-splices settings at EVERY start, so these values
      # are the durable source of truth; hand-edits to the live yaml get
      # reverted by the next restart.
      filtering = {
        protection_enabled = true;  # pipeline runs; blocklists below stay empty
        filtering_enabled = true;
        rewrites = [
          # --- services (full words); dav/cal/dns live on an (pi), rest on wa ---
          { domain = "immich.wyli.tech"; answer = "100.68.142.0"; enabled = true; }   # wa (warden)
          { domain = "dav.wyli.tech";    answer = "100.95.249.82"; enabled = true; }  # an — radicale
          { domain = "cal.wyli.tech";    answer = "100.95.249.82"; enabled = true; }  # an — wycal UI (future)
          { domain = "stt.wyli.tech";    answer = "100.68.142.0"; enabled = true; }   # wa
          { domain = "matrix.wyli.tech"; answer = "100.68.142.0"; enabled = true; }   # wa (gated off, plan 10 pending)
          { domain = "dns.wyli.tech";    answer = "100.95.249.82"; enabled = true; }  # an — AGH admin
          { domain = "ms.dev.wyli.tech"; answer = "100.68.142.0"; enabled = true; }   # wa — dev lanes
          # --- machines (fleet short forms, PLAN.md §0.1) ---
          { domain = "wa.wyli.tech"; answer = "100.68.142.0"; enabled = true; }       # warden
          { domain = "sd.wyli.tech"; answer = "100.84.47.44"; enabled = true; }       # scout-darwin
          { domain = "sa.wyli.tech"; answer = "100.64.0.2"; enabled = true; }         # scout-asahi (not joined yet)
          { domain = "rg.wyli.tech"; answer = "100.127.195.50"; enabled = true; }     # rogue-glyph
          { domain = "an.wyli.tech"; answer = "100.95.249.82"; enabled = true; }      # artificer-nixos (this host)
        ];
      };
    };
  };

  # DNS + admin reachable from the tailnet only
  networking.firewall.interfaces."tailscale0" = {
    allowedTCPPorts = [ 53 3000 ];
    allowedUDPPorts = [ 53 ];
  };
}
