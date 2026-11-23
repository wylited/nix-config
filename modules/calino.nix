# modules/calino.nix — cal.ts.wyli.tech: Calino, the CalDAV web client.
#
# Replaces wycal (2026-11-24). Same shape as the old module: a static Vite
# build on a loopback port, fronted by the existing cal.ts.wyli.tech caddy
# route. The browser talks to dav.ts.wyli.tech directly (that vhost carries
# the CORS headers), so there is no proxy and no server-side session.
#
# Calino is local-first: accounts and settings live in the browser, and the
# credentials in calino.config.json are encrypted with a master password the
# user would otherwise type on first load. Warden's radicale is passwordless
# behind the tailnet (modules/caldav.nix), so there is nothing to protect:
# scripts/calino-warden-bootstrap.mjs bakes a throwaway master password into
# the bundle and seeds the matching localStorage key from dist/bootstrap.js.
# The result is no login screen, no account setup, no "connect" button.
#
# The CalDAV password below is a dummy — radicale accepts any user/password
# pair with auth.type = "none" and keys collections by the username, which
# must stay "wyli" to reach /wyli/*.
{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.services.calino;

  calino = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "calino";
    version = "0.42.0";

    src = pkgs.fetchFromGitHub {
      owner = "Ivan-Malinovski";
      repo = "calino";
      rev = "5923ea08e63a6e420ef372db84a97b4971346493"; # v0.42.0
      hash = "sha256-zoBzuL1adjFG1EIwBfvM3VGefa+YKlGbLUSh/z9baAM=";
    };

    pnpmDeps = pkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pkgs.pnpm_10;
      fetcherVersion = 5;
      # Regenerate after bumping src: build with hash = lib.fakeHash and copy
      # the "got:" value out of the fixed-output mismatch.
      hash = "sha256-PGL2OZZltSUB9J1rfxtSwY0+90q225vjCihltVugCiU=";
    };

    nativeBuildInputs = [
      pkgs.nodejs_24
      pkgs.pnpm_10
      pkgs.pnpmConfigHook
    ];

    # Config is read by vite.config.ts before the bundle is built, so the
    # account exists on the first paint. Keep in sync with the script's env.
    env = {
      CALINO_DAV_URL = cfg.davUrl;
      CALINO_DAV_USER = cfg.username;
      CALINO_DAV_PASS = cfg.password;
      CALINO_ACCOUNT_NAME = cfg.accountName;
      CALINO_MASTER_PASSWORD = cfg.masterPassword;
      VITE_SITE_URL = "https://cal.ts.wyli.tech";
    };

    # The checkout is read-only in the store; keep the helper with the module.
    postPatch = ''
      cp ${./calino-warden-bootstrap.mjs} scripts/calino-warden-bootstrap.mjs
    '';

    preBuild = ''
      node scripts/calino-warden-bootstrap.mjs config
    '';

    # Same steps as the project's Dockerfile: sample-event dates, then a bare
    # vite build. `pnpm build` would also typecheck, which is upstream CI's job.
    # Overriding buildPhase skips the default function, so preBuild/postBuild
    # (config + dist patch) must be invoked here by hand.
    buildPhase = ''
      runHook preBuild
      node scripts/update-sample-events.mjs
      pnpm exec vite build
      runHook postBuild
    '';

    postBuild = ''
      node scripts/calino-warden-bootstrap.mjs dist
    '';

    installPhase = ''
      cp -r dist $out
    '';

    meta = {
      description = "Calino — CalDAV + CardDAV web client (static build)";
      homepage = "https://github.com/Ivan-Malinovski/calino";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  });
in
{
  options.services.calino = {
    enable = lib.mkEnableOption "Calino CalDAV web client";

    package = lib.mkOption {
      type = lib.types.package;
      default = calino;
      description = "Calino static site package (dist/ tree)";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "listen address";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8423;
      description = "listen port (matches the cal.ts.wyli.tech caddy route)";
    };

    accountName = lib.mkOption {
      type = lib.types.str;
      default = "Warden";
      description = "display name of the preconfigured CalDAV account";
    };

    davUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://dav.ts.wyli.tech";
      description = "CalDAV server URL the browser dials (needs CORS)";
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "wyli";
      description = "CalDAV username; radicale keys collections by it";
    };

    password = lib.mkOption {
      type = lib.types.str;
      default = "calino";
      description = ''
        CalDAV password. radicale runs auth.type = "none", so any value is
        accepted; this is a dummy that keeps DAV clients happy.
      '';
    };

    masterPassword = lib.mkOption {
      type = lib.types.str;
      default = "warden-calino-local";
      description = ''
        Master password for calino.config.json. Never typed by a human: the
        matching app-key-encrypted copy is seeded into localStorage by
        bootstrap.js. Obfuscation only, like the app's own credential store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.calino = {
      description = "calino — CalDAV web client (static, cal.ts.wyli.tech)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        # --spa: Calino's router redirects / to /month and deep links like
        # /settings must not 404. --disable-indexing keeps directory listings
        # off; the hashed assets are still served.
        ExecStart = "${lib.getExe pkgs.miniserve} --interfaces ${cfg.address} --port ${toString cfg.port} --index index.html --spa --disable-indexing ${cfg.package}";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
