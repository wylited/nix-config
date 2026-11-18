# Client for the ECE Makerspace lab binary cache (https://attic.ecemaker.space/maker).
# Mirrors ece-makerspace/lab-nixos features/attic-client.nix: same machine token
# (r+w+cc on the `maker` cache), same signing key — closures built here or on
# eez156 substitute in both directions.
#
# The push token lives OUTSIDE the repo at /etc/nix/attic-token.txt (0600).
# Never commit it: the fleet flake is evaluated from git trees and from a
# public repo, and `environment.etc.*.text` would copy any embedded secret
# into the world-readable store. The activation script below reads the token
# at switch time, so only the path (never the value) enters the store.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  endpoint = "https://attic.ecemaker.space";
  cacheName = "maker";
  # Token lives OUTSIDE the repo at /etc/nix/attic-token.txt (mode 0600):
  # git-tree flake evals can't see gitignored files, so an in-repo token file
  # silently no-ops on rebuilds. Absolute path = machine-local secret; the
  # sops-nix migration (plan 03) will own this file later. Absent file =>
  # module no-ops and nix uses the official cache only.
  tokenPath = "/etc/nix/attic-token.txt";
  hasToken = builtins.pathExists tokenPath;
in
{
  config = lib.mkIf hasToken {
    users.groups.attic-push = { };

    # Written at activation from the host-side token, never from a store path:
    # the file text would otherwise be baked into a world-readable derivation.
    system.activationScripts.attic-config = {
      deps = [ "users" ];
      text = ''
        token="$(cat ${tokenPath})"
        install -d -m 0755 /etc/attic
        # Replace the old environment.etc files (symlinks in earlier
        # generations) with root-owned regular files.
        rm -f /etc/attic/config.toml /etc/nix/netrc
        cat > /etc/attic/config.toml <<EOF
        default-server = "attic"

        [servers.attic]
        endpoint = "${endpoint}"
        token = "$token"
        EOF
        chown root:attic-push /etc/attic/config.toml
        chmod 0640 /etc/attic/config.toml

        printf 'machine attic.ecemaker.space login attic password %s\n' "$token" \
          > /etc/nix/netrc
        chown root:root /etc/nix/netrc
        chmod 0600 /etc/nix/netrc
        unset token
      '';
    };

    nix.settings = {
      substituters = [
        "${endpoint}/${cacheName}"
        "https://cache.nixos.org/"
      ];
      trusted-public-keys = [
        "maker:L6hBPi59/8dc+u90+GtX922PftxOh9ElwOpkS9cB2n0="
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
      netrc-file = "/etc/nix/netrc";
      builders-use-substitutes = true;
      connect-timeout = 10;
      stalled-download-timeout = 10;
    };

    environment.systemPackages = [ pkgs.attic-client ];

    # Pushes every path that enters the local store; paths already in the cache
    # are skipped, so a machine that mostly substitutes re-uploads ~nothing.
    systemd.services.attic-watch-store = {
      description = "Attic store watcher: push new store paths to ${cacheName}";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.attic-client}/bin/attic watch-store attic:${cacheName}";
        Environment = "XDG_CONFIG_HOME=/etc";
        Restart = "on-failure";
        RestartSec = 10;
        DynamicUser = true;
        SupplementaryGroups = [ "attic-push" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
