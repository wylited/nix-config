# Design, evidence and the Beeper migration procedure: ~/nix-migration/10-matrix-on-warden.md
# Implementation: modules/matrix/ (Synapse, postgres, bridges, ingress, watchdog, backup).
{ ... }:

{
  imports = [ ../../modules/matrix ];

  services.matrixStack = {
    enable = true;

    # Immutable once accounts exist. matrix.wyli.tech: tailnet-only name via
    # AGH rewrites (not public), served by warden's caddy on plain :80 —
    # WireGuard encrypts the transport; no tailscale-serve, no tokens
    # (2026-10-26 decision). Changed BEFORE the first account existed.
    serverName = "matrix.wyli.tech";
    clientUrl = "https://matrix.ts.wyli.tech";   # LE wildcard via deSEC (2026-10-27); identity stays @user:matrix.wyli.tech

    owner = "wyli";

    bridges = {
      # The three networks currently bridged in Beeper Desktop.
      whatsapp.enable = true;
      instagram.enable = true;
      discord.enable = true;

      # Per-bridge tweaks go here; anything not set keeps the stack defaults
      # (loopback listener, postgres, E2EE-with-pickle-key, owner=admin).
      # Full history backfill (Beeper-parity UX, 2026-10-27): whatsmeow's
      # native WhatsApp history-sync does the import; throttled by design so
      # first sync takes a while on big histories. `sync` in the bot DM pulls
      # a specific chat immediately.
      whatsapp.settings.bridge = {
        history_sync = {
          full_sync = true;
          create_portals = true;
          max_conversations = 200;
          recent_hours = 168;    # prioritize the last week of chats
        };
        backfill = {
          enable = true;
          max_initial_events = 500;
          unread_hours_threshold = 720;
        };
      };
    };

    watchdog = {
      # Wired 2026-10-26 — two-step bring-up (units live in watchdog.nix):
      #   1. this deploy: matrix-alert-bot.service registers
      #      @matrix-alert:matrix.wyli.tech (random password + access token
      #      under /var/lib/matrix-secrets/); matrix-alert-join.timer waits
      #      for the invite.
      #   2. wyli creates a private alert room and invites
      #      @matrix-alert:matrix.wyli.tech (joined within 15 min), then the
      #      placeholder below is replaced with the real room id
      #      (!…:matrix.wyli.tech) and the switch lands. Until then a
      #      degraded tick reports alert-delivery failures on top of the real
      #      problems — best-effort by design, nothing is swallowed.
      # Token file is the option default: /var/lib/matrix-secrets/alert-token.
      alertRoom = "!qhDRunFgTEDDdgrgKK:matrix.wyli.tech";   # "Fleet Alerts" — live 2026-10-27
    };

    # plain-http caddy ingress instead (matrix.wyli.tech → :80 → synapse);
    # tailscale serve rejected by user 2026-10-26
    ingress.tailscaleServe.enable = false;
  };
}
