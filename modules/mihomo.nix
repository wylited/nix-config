# Mihomo as a system VPN (TUN) on macOS, managed by launchd.
#
# The proxy credentials in the config file are deliberately NOT in this repo:
# it is public. The live config lives at the path below, mode 0600, and is
# generated from the Terraform output of ../homelab/infra/gcp-ranger.
{ pkgs, ... }:

let
  configPath = "/Users/wyli/.config/mihomo/config.yaml";
in
{
  environment.systemPackages = [ pkgs.mihomo ];

  # `script` runs as root from launchd, so it can create the TUN and the
  # runtime directory. nix-darwin only injects a fixed set of activation
  # script names, so do this here rather than in system.activationScripts.
  launchd.daemons.mihomo = {
    script = ''
      mkdir -p /var/lib/mihomo
      chmod 700 /var/lib/mihomo
      ln -sfn ${pkgs.metacubexd} /var/lib/mihomo/ui
      exec ${pkgs.mihomo}/bin/mihomo -d /var/lib/mihomo -f ${configPath}
    '';

    serviceConfig = {
      Label = "org.nixos.mihomo";
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardOutPath = "/var/log/mihomo.log";
      StandardErrorPath = "/var/log/mihomo.log";
      ThrottleInterval = 5;
    };
  };
}
