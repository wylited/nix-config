# dash-proxy — tailnet-only JSON for dash.ts.wyli.tech's Proxy panel.
#
# Runs on the Mac because that is where the gcloud ADC and mihomo controller
# live. Warden's Caddy proxies /proxy/* to this port; nothing is exposed on
# the LAN or public internet. The bind address is the Mac's stable Tailscale
# IPv4; if the node is re-created, update it here and in modules/dashboard.nix.
#
# The daemon runs as the login user, not root: gcloud ADC is per-user, and the
# port is >1024. No third-party Python packages.
{ pkgs, ... }:

let
  tailscaleIP = "100.84.47.44";
  port = 9091;
in
{
  launchd.user.agents.dash-proxy = {
    script = ''
      mkdir -p /Users/wyli/Library/Logs
      exec ${pkgs.python3}/bin/python3 ${../scripts/dash-proxy.py} \
        --host ${tailscaleIP} --port ${toString port}
    '';

    serviceConfig = {
      Label = "org.nixos.dash-proxy";
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      EnvironmentVariables = {
        HOME = "/Users/wyli";
        PATH = "${pkgs.google-cloud-sdk}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      StandardOutPath = "/Users/wyli/Library/Logs/dash-proxy.log";
      StandardErrorPath = "/Users/wyli/Library/Logs/dash-proxy.log";
      ThrottleInterval = 5;
    };
  };
}
