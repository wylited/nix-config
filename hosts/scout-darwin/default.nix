{ pkgs, self, inputs, ... }:

let
  androidPkgs = pkgs.androidenv.composeAndroidPackages;
  androidSdk = (androidPkgs {
    platformVersions = [ "36" ];
    buildToolsVersions = [ "35.0.0" "36.0.0" ];
  }).androidsdk;
in
{
  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.android_sdk.accept_license = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [
    android-tools
    jdk21
    androidSdk
    bat
    bun
    clang
    cocoapods
    watchman
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
    emacs
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
