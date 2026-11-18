{ config, pkgs, inputs, ... }:

{
  home.username = "wyli";
  home.homeDirectory = if pkgs.stdenv.hostPlatform.isDarwin then "/Users/wyli" else "/home/wyli";
  home.stateVersion = "25.11";

  imports = [
    inputs.zen-browser.homeModules.twilight
    inputs.rex.homeManagerModules.default
  ];

  # rex: on Linux, CLI + terminfo + personal server (linger is set on the
  # host, so it survives logout). On macOS the GUI app owns the server and
  # we only install the CLI from the flake's systemPackages — enabling the
  # HM module there would warn about ~/.ssh/config, which stays manual.
  # Remote access is plain ssh:// — no Tailscale Serve hop.
  programs.rex.enable = pkgs.stdenv.hostPlatform.isLinux;
  services.rex.enable = pkgs.stdenv.hostPlatform.isLinux;
  # No ssh TERM guard: it is a `Match exec` block with an unquoted %h, and
  # taking over ~/.ssh/config for it is more surface than the TERM nicety is
  # worth. `rex terminfo setup` can add it by hand if ssh-from-Rex breaks.
  programs.rex.sshGuard = false;

  programs.zen-browser = {
    enable = true;
  };

  fonts.fontconfig.enable = true;

  xdg.configFile."fontconfig/fonts.conf".text = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <include ignore_missing="yes">conf.d</include>
      <dir>~/.nix-profile/share/fonts</dir>
      <dir>/Applications/Nix Apps</dir>
      <dir>/System/Library/Fonts</dir>
      <dir>/Library/Fonts</dir>
      <dir>~/Library/Fonts</dir>
    </fontconfig>
  '';

  home.sessionVariables.FONTCONFIG_FILE =
    "${config.xdg.configHome}/fontconfig/fonts.conf";

  programs.vesktop = {
    enable = true;

    vencord.settings = {
      autoUpdate = true;
      autoUpdateNotification = true;
      notifyAboutUpdates = true;

      plugins = {
        ClearURLs.enabled = true;
        FixYoutubeEmbeds.enabled = true;
      };
    };
  };

  # TODO (plan 07): move linux hosts to homeDirectory "/home/wyli" — either a
  # `lib.mkIf pkgs.stdenv.isDarwin` split here or per-host override via
  # home-manager.users.wyli.home.homeDirectory. Also: omp/pi config parity via
  # home.file (see 07-omp-pi-parity.md).
}
