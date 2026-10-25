# warden — Matrix stack: what this host runs and who owns it.
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
    clientUrl = "http://matrix.wyli.tech";

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

    # plain-http caddy ingress instead (matrix.wyli.tech → :80 → synapse);
    # tailscale serve rejected by user 2026-10-26
    ingress.tailscaleServe.enable = false;
  };
}
