# Synapse + the shared PostgreSQL cluster.
#
# Two decisions worth the words:
#
# 1. One PostgreSQL cluster for Synapse and every bridge, created with
#    `--locale=C`. Synapse's docs require the C collation; the mautrix Go
#    bridges require PostgreSQL >= 16. One cluster means one dump path, one
#    restore procedure, one thing to watch.
# 2. No database passwords anywhere. Role names are chosen to equal the
#    systemd user that each service runs as (`matrix-synapse`,
#    `mautrix-whatsapp`, …) and NixOS's default `pg_hba.conf` authenticates
#    unix-socket connections with `peer`, so the kernel checks identity for us.
#    nixpkgs' own `mautrix-meta-postgres` NixOS test exercises exactly this
#    combination (peer auth + the module's `PrivateUsers = true`) and passes, so
#    the bridge hardening sandbox does not have to be weakened for it.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.matrixStack;
  allDatabases = cfg.databases;
in
{
  options.services.matrixStack.homeserver = {
    maxUploadSize = lib.mkOption {
      type = lib.types.str;
      default = "200M";
      description = ''
        Synapse `max_upload_size`. Defaults above WhatsApp's own media ceiling
        so nothing fails at the homeserver instead of the network.
      '';
    };

    extraSettings = lib.mkOption {
      type = lib.types.json;
      default = { };
      example = { url_preview_enabled = true; };
      description = ''
        Extra `homeserver.yaml` settings, merged over the stack defaults.
        Secrets do not belong here — the store is world-readable; use the
        generated `secrets.nix` config file instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      initdbArgs = [
        "--encoding=UTF8"
        "--locale=C" # Synapse's documented requirement; the bridges don't care
      ];
      ensureDatabases = allDatabases;
      # `ensureDBOwnership` matters on PostgreSQL >= 15: the public schema is no
      # longer writable by everyone, so each service must own its database.
      ensureUsers = map (name: {
        inherit name;
        ensureDBOwnership = true;
      }) allDatabases;
    };

    services.matrix-synapse = {
      enable = true;

      settings = lib.recursiveUpdate {
        server_name = cfg.serverName;
        public_baseurl = "${cfg.clientUrl}/";
        enable_registration = false;

        listeners = [
          {
            port = cfg.listenPort;
            bind_addresses = [ cfg.listenAddress ];
            type = "http";
            tls = false;
            x_forwarded = true; # clients arrive through `tailscale serve`
            resources = [
              {
                names = [ "client" ];
                compress = true;
              }
              {
                names = [ "federation" ];
                compress = false;
              }
            ];
          }
        ];

        database = {
          name = "psycopg2"; # nixpkgs defaults user/database to "matrix-synapse"
          args.host = "/run/postgresql";
        };

        max_upload_size = cfg.homeserver.maxUploadSize;

        # No outbound requests from the homeserver: previews are the only thing
        # that would need them, and this server is tailnet-only. Flip to true
        # (keeping the module's IP blacklist) if previews are wanted.
        url_preview_enabled = false;
      } cfg.homeserver.extraSettings;

      # Appended after the store config, so it wins. Holds macaroon_secret_key,
      # registration_shared_secret and form_secret, generated once on the host
      # (./secrets.nix) — the alternative is `settings`, which is world-readable
      # in /nix/store.
      extraConfigFiles = [ "${cfg.secrets.directory}/synapse-secrets.yaml" ];
    };

    # The generated config file must exist before Synapse reads it, and every
    # registration service (bridges.nix) writes tokens that Synapse then loads.
    #
    # Ordering on postgres is added by hand on purpose: Synapse's
    # `hasLocalPostgresDB` heuristic (synapse.nix:30) only matches host values
    # of localhost/127.0.0.1/::1, so pointing it at the unix socket — which is
    # what gives us peer auth — makes the module skip the dependency entirely.
    systemd.services.matrix-synapse = {
      # `wants`, not `requires`: systemd propagates *stop* through Requires, and
      # a unit stopped by dependency propagation is not restarted by
      # `Restart=always`. With Require= a plain `systemctl restart postgresql`
      # would leave the homeserver down until someone started it by hand.
      wants = [ "postgresql.target" "matrix-secrets.service" ];
      after = [ "postgresql.target" "matrix-secrets.service" ];
      serviceConfig = {
        # Same reasoning as the bridges: `on-failure` leaves a cleanly exited
        # Synapse down until someone notices, and a homeserver that is down
        # while its bridges are up loses messages.
        Restart = lib.mkForce "always";
        RestartSec = lib.mkForce "5s";
      };
    };

    # One-time account creation is deliberately NOT automated: it needs a
    # password, and a password in Nix is a password in the store. Run once:
    #   sudo -u matrix-synapse matrix-synapse-register_new_matrix_user -u wyli -a
    # The wrapper the module installs already carries the merged config path, so
    # the registration shared secret from ./secrets.nix is picked up.
    environment.systemPackages = [
      # psql/pg_dump for the restore drills documented in the plan
      config.services.postgresql.package
    ];
  };
}
