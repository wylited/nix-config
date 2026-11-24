{ pkgs, self, inputs, ... }:

let
  androidPkgs = pkgs.androidenv.composeAndroidPackages;
  androidSdk = (androidPkgs {
    platformVersions = [ "36" ];
    buildToolsVersions = [ "35.0.0" "36.0.0" ];
  }).androidsdk;
in
{
  imports = [ ../../modules/mihomo.nix ../../modules/dash-proxy.nix ];

  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.android_sdk.accept_license = true;

  # The pre-repo nix-darwin generation left /etc/resolver/ts.net as a store
  # symlink; tailscaled refuses to manage DNS over it ("openat ts.net: path
  # escapes from parent"). Tailscale wants a regular file there, so drop only
  # a symlink and let the daemon re-create it.
  # postActivation, not a custom name: nix-darwin only runs its known hooks,
  # and this has to run after `etc` re-creates the symlink.
  system.activationScripts.postActivation.text = pkgs.lib.mkAfter ''
    if [ -L /etc/resolver/ts.net ]; then
      rm -f /etc/resolver/ts.net
      launchctl kickstart -k system/com.tailscale.tailscaled || true
    fi
  '';

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Agent CLIs are npm/bun globals (pi self-updates; nix can't own the prefix),
  # but a plain login shell must find them. nix-darwin's /etc/zshenv resets
  # PATH from set-environment, then sources this file — so prepending here is
  # the one seam that survives reboots. Without it `pi`/`omp` only resolve in
  # harness-injected shells (observed 2026-11-18: clean `zsh -lc` had neither).
  environment.etc."zshenv.local".text = ''
    export PATH="$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"
  '';

  environment.systemPackages = with pkgs; [
    inputs.rex.packages.${pkgs.stdenv.hostPlatform.system}.rex  # CLI; GUI app installed manually
    android-tools
    jdk21
    curl-impersonate
    cloudflared
    gost
    syncthing
    androidSdk
    bat
    catt
    bun
    clang
    tree
    google-cloud-sdk
    cocoapods
    watchman
    fastfetch
    glow
    coreutils-prefixed
    delta
    fd
    fish
    gh
    git
    go
    graphviz
    helix
    just
    nixfmt
    nodejs_24
    pandoc
    pnpm
    python3
    ripgrep
    rustup
    shellcheck
    uv
    vim
    wget
    yarn
    zig
    syncthing
    firefox
    google-chrome
    openscad
    raycast
    zoxide
    fzy
    wireshark
    tshark
    ghidra
    bottom
    docker-client
    sshpass
    ffmpeg_7
    tinymist
    colima
    kitty
    postgresql
    jadx
    yaak
    dust
    tenv
    # Emacs binaries only — suppress the GUI app symlink so Spotlight resolves
    # "Emacs" to the ~/Applications client wrapper (attaches to the daemon).
    (pkgs.runCommand "emacs-bin" { } ''
      mkdir -p $out/bin
      ln -s ${pkgs.emacs}/bin/* $out/bin
    '')
    qbittorrent
    libtinfo
    esptool
    skimpdf
  ];

  fonts.packages = with pkgs; [
    symbola
    lexend
    iosevka
    nerd-fonts.fira-code
    nerd-fonts.iosevka
    nerd-fonts.symbols-only
    atkinson-hyperlegible
    raleway
    libertinus
  ];

  environment.variables = {
    ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
    JAVA_HOME = "${pkgs.jdk21.home}";
  };

  programs.fish.enable = true;
  services.emacs.enable = true;
  services.tailscale.enable = true;

  users.knownUsers = [ "wyli" ];
  users.users.wyli = {
    uid = 501;
    home = "/Users/wyli";
    shell = pkgs.fish;
  };

  system.primaryUser = "wyli";

  system.defaults = {
    NSGlobalDomain = {
      KeyRepeat = 1;
      InitialKeyRepeat = 9;
      ApplePressAndHoldEnabled = false;
    };

    dock.autohide = true;

    LaunchServices.LSQuarantine = false;

    CustomUserPreferences."com.apple.dock" = {
      autohide-time-modifier = 0.5;
    };

    # Stop App Nap from throttling Emacs between keystrokes (input lag on macOS)
    CustomUserPreferences."org.gnu.Emacs" = {
      NSAppSleepDisabled = true;
      # macOS 26 event-loop fixes: trackpad scroll lag / delayed frames
      # (Emacs bug#80268)
      NSApplicationUpdateCycleEnabled = false;
      NSEventConcurrentProcessingEnabled = false;
    };
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    extraSpecialArgs = { inherit self inputs; };

    users.wyli = { imports = [ ../../home/wyli.nix ]; };
  };

  system.configurationRevision = self.rev or self.dirtyRev or null;
  system.stateVersion = 6;
}
