# warden — Matrix stack: what this host runs and who owns it.
# Design, evidence and the Beeper migration procedure: ~/nix-migration/10-matrix-on-warden.md
# Implementation: modules/matrix/ (Synapse, postgres, bridges, ingress, watchdog, backup).
{ ... }:

{
  imports = [ ../../modules/matrix ];

  services.matrixStack = {
    enable = true;

    # Immutable once the homeserver has been used: it is in every user id, room
    # id and access token. `warden` is the tailnet MagicDNS name of this host
    # (tailnet story-tiaki.ts.net), which is also the certificate `tailscale
    # serve` gets, so no domain registration or .well-known delegation is needed.
    serverName = "warden.story-tiaki.ts.net";
    clientUrl = "https://warden.story-tiaki.ts.net";

    owner = "wyli";

    bridges = {
      # The three networks currently bridged in Beeper Desktop.
      whatsapp.enable = true;
      instagram.enable = true;
      discord.enable = true;

      # Per-bridge tweaks go here; anything not set keeps the stack defaults
      # (loopback listener, postgres, E2EE-with-pickle-key, owner=admin).
      # whatsapp.settings.bridge.private_chat_portal_meta = true;
    };

    watchdog = {
      # Set both of these to get degraded-state alerts inside Matrix itself
      # (create a room, grab its id, then store an access token in
      # /var/lib/matrix-secrets/alert-token). Journal-only until then.
      alertRoom = null;
    };
  };
}
