# Client for the ECE Makerspace lab binary cache (https://attic.ecemaker.space/maker).
# Mirrors ece-makerspace/lab-nixos features/attic-client.nix: same machine token
# (r+w+cc on the `maker` cache), same signing key — closures built here or on
# eez156 substitute in both directions.
#
# The push token lives in modules/attic-token.txt (gitignored). Before
# system.autoUpgrade evaluates this flake from anywhere but a full checkout
# (plan 08 TODO), the token must move to sops-nix (plan 03) or ship with the
# checkout.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  endpoint = "https://attic.ecemaker.space";
  cacheName = "maker";
  # Token file is gitignored (this repo is public). When absent — e.g. a fresh
  # clone on a new machine — the module no-ops and nix uses the official cache
  # only; the few warden-specific paths just build locally. Paste the token
  # into modules/attic-token.txt to activate the lab cache.
  tokenPath = ./attic-token.txt;
  hasToken = builtins.pathExists tokenPath;
in
{
  config = lib.mkIf hasToken {
    users.groups.attic-push = { };

    environment.etc = {
      # attic CLI config; watch-store reads it via XDG_CONFIG_HOME=/etc
      "attic/config.toml" = {
        text = ''
          default-server = "attic"

          [servers.attic]
          endpoint = "${endpoint}"
          token = "${lib.removeSuffix "\n" (builtins.readFile tokenPath)}"
        '';
        mode = "0640";
        group = "attic-push";
      };

      # basic-auth credentials with which the nix daemon pulls from the private cache
      "nix/netrc" = {
        text = ''
          machine attic.ecemaker.space login attic password ${lib.removeSuffix "\n" (builtins.readFile tokenPath)}
        '';
        mode = "0600";
      };
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
