# modules/desktop.nix — plan 13: lightweight Wayland console on the TV
# (sway + greetd autologin + pipewire + mpv/VAAPI), plus the plumbing the
# Android emulator needs (KVM group is host-side; see wiring note below).
#
# ACTIVATED 2026-10-28: imported by hosts/warden — TV console + Sunshine
# streaming to the Mac (Moonlight client). `kvm` is still NOT in wyli's
# extraGroups: it rides with the Android-emulator decision below.
#
# Compositor decision (2026-10-25): sway — the boring one. wlroots-based, a
# decade of mileage, the only option with first-class NixOS (programs.sway
# wrapper) AND home-manager config generation; runs output-less (wlroots
# 0.16+), so boot with the TV off is a non-event and HDMI hotplug re-attaches
# via kanshi. Rejected:
#   labwc    — NixOS module is package-only, XML config hand-rolled;
#   cage     — kiosk compositor: one fullscreen client, can't sit next to a
#              terminal or the Android emulator (revisit as a kiosk layer
#              later if the TV use ossifies);
#   hyprland — heavier closure, fast-moving surface — the opposite of boring.
#
# Session path: greetd (no greeter binary, no display manager, no X) →
# initial_session = sway as wyli, driven by the amdgpu iGPU ONLY. The RTX 3050
# stays compute-only (whisper.nix Mode B) — nothing here touches
# hardware.nvidia; services.xserver.enable stays unset.
#
# No lock screen by design: physical access to the TV is the login (the host
# already runs sudo.wheelNeedsPassword=false under the same reasoning).
# wayvnc ships but never auto-starts; ad-hoc over tailnet only:
#   wayvnc $(tailscale ip -4) 5900
#
# Open decisions (2026-10-25): Android SDK strategy (recommend unfree
# android-studio with self-managed ~/Android/Sdk — needs the unfree predicate
# + android_sdk.accept_license; alternatives: tadfisher/android-nixpkgs
# devshell, androidenv) · kanshi criteria "*" → pin real connector/mode via
# `swaymsg -t get_outputs` after first TV boot · 900 s DPMS timeout tune.
{ config, lib, pkgs, ... }:
{
  # ---------------- compositor + seat ----------------
  programs.sway = {
    enable = true;               # setuid wrapper + session env; XWayland for
                                 # Android Studio / emulator (Qt, X11-flavored)
    wrapperFeatures.gtk = true;  # portal/theme env for GTK apps
    extraPackages = with pkgs; [ swayidle ];  # replaces default swaylock set
  };

  services.greetd = {
    enable = true;
    settings = rec {
      # autologin with no greeter process; default_session mirrors it so an
      # exited/crashed sway respawns instead of dropping to a login prompt
      initial_session = {
        command = "${pkgs.sway}/bin/sway";
        user = "wyli";
      };
      default_session = initial_session;
    };
  };
  # Boot safety: greetd is an ordinary systemd unit — ssh/docker/tailscale on
  # multi-user.target never wait on it, and sway runs output-less when the TV
  # is off (sway ≥1.8); the HDMI connector appears on hotplug and kanshi
  # re-pins the mode. Worst case: black VT, reachable server.

  # ---------------- audio over HDMI ----------------
  security.rtkit.enable = true;          # realtime scheduling for pipewire
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;                 # pulse clients (mpv, chromium) as-is
    # permanent null sink: with the TV off there is no HDMI sink and the
    # Sunshine stream would be silent — wireplumber falls back to this as
    # default sink whenever HDMI is absent.
    extraConfig.pipewire."90-stream-sink" = {
      "context.objects" = [ {
        factory = "adapter";
        args = {
          "factory.name" = "support.null-audio-sink";
          "node.name" = "stream_sink";
          "node.description" = "Stream sink (no TV)";
          "media.class" = "Audio/Sink";
          "audio.position" = [ "FL" "FR" ];
          "object.linger" = true;
        };
      } ];
    };
  };
  # wireplumber (the default manager) selects the HDMI sink automatically
  # when the TV connects.

  # ---------------- shared plumbing ----------------
  fonts.packages = [ pkgs.dejavu_fonts ];    # the one font foot/fuzzel/mpv need
  xdg.portal = {                             # screenshare & friends
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk pkgs.xdg-desktop-portal-wlr ];
    config.sway.default = lib.mkForce [ "wlr" "gtk" ];  # NixOS sway.nix also sets this — wlr first is ours
  };

  # ---------------- streaming to the Mac (Moonlight client) ----------------
  # waypipe needs a Wayland compositor at the viewing end — macOS has none, so
  # Sunshine streams the whole sway session instead: wlr-screencopy capture +
  # VAAPI encode on the Cezanne iGPU, input via /dev/uinput, audio via pipewire.
  services.sunshine = {
    enable = true;
    autoStart = true;        # user unit, starts with graphical-session.target
    capSysAdmin = false;     # wlr capture — no KMS privilege needed
    # openFirewall stays off on purpose: tailscale0 is trusted (ts-input chain
    # accepts tailnet traffic before nixos-fw), so Sunshine's ports
    # 47984/47989/47990/48010 TCP + 47998-48010 UDP are tailnet-only.
    settings = {
      capture = "wlr";       # sway = wlroots; first output = TV when on,
                             # HEADLESS-1 otherwise (see sway startup below)
      origin_web_ui_allowed = "wan";  # pair from the Mac's browser over the
                                      # tailnet; firewall keeps 47990 closed off-tailnet
    };
  };
  hardware.uinput.enable = true;                # virtual kbd/mouse/gamepad
  users.users.wyli.extraGroups = [ "uinput" ];  # merges with warden's groups

  environment.systemPackages = with pkgs; [
    libva-utils    # vainfo — verify radeonsi VA-API on the iGPU
    android-tools  # adb/fastboot now; emulator itself = open decision
    wayvnc         # tailnet-only, manual (see header)
    supertuxkart   # native app proof: streamed to the Mac, Vega 8 via radv
  ];

  # ---------------- home: sway session, kanshi, mpv ----------------
  # Deliberately NOT in home/wyli.nix — that file is shared with the Macs.
  home-manager.users.wyli = {
    home.packages = with pkgs; [
      fuzzel         # wayland-native launcher ($mod+d)
      wl-clipboard
      (writeShellScriptBin "tvplay" ''
        # throw a file at the TV from anywhere:
        #   ssh warden-arch tvplay ~/Movies/x.mkv
        exec env WAYLAND_DISPLAY=wayland-0 \
          XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/1000}" \
          mpv --fs "$@"
      '')
    ];

    programs.foot.enable = true;   # terminal ($mod+Return)

    services.kanshi = {
      enable = true;               # binds graphical-session.target
      settings = [
        {
          profile.name = "tv";
          profile.outputs = [
            {
              # any output, preferred mode — sway's hotplug default, but
              # kanshi re-pins it across TV standby/wake EDID flaps. Pin the
              # real connector + mode once known: swaymsg -t get_outputs
              criteria = "*";
              status = "enable";
            }
          ];
        }
      ];
    };

    wayland.windowManager.sway = {
      enable = true;               # generates ~/.config/sway/config
      config = {
        terminal = "foot";
        bars = [ ];                # TV, not a workstation
        keybindings = {
          # explicit set — defining keybindings replaces HM's defaults
          "Mod4+Return" = "exec foot";
          "Mod4+d" = "exec fuzzel";
          "Mod4+Shift+q" = "kill";
          "Mod4+Shift+c" = "reload";
          "Mod4+Shift+e" = "exec swaymsg exit";
        };
        startup = [
          {
            # DPMS-off after 15 min idle; mpv holds the idle-inhibit protocol
            # while playing, so movies never blank. No locker (see header).
            command = "swayidle -w timeout 900 'swaymsg output * dpms off' resume 'swaymsg output * dpms on'";
          }
          {
            # TV-off boot: zero outputs = nothing to capture — synthesize a
            # headless one so Sunshine always has a surface. TV present at
            # start → the grep matches, no synthetic output.
            command = "sh -c 'swaymsg -t get_outputs | grep -q active || swaymsg create_output'";
          }
        ];
      };
    };

    programs.mpv = {
      enable = true;
      # VAAPI on the amdgpu iGPU (Mesa radeonsi; already wired via
      # hardware.graphics in whisper.nix). auto-safe = hardware decode when
      # safe, silent CPU fallback otherwise — Cezanne VCN: h264/hevc/vp9 yes,
      # AV1 no (the 5800H covers 1080p AV1 in software). Verify: vainfo.
      config = {
        hwdec = "auto-safe";
        vo = "gpu-next";
      };
    };
  };
}
