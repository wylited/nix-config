# modules/immich.nix — plan 12 §2: native services.immich, FRESH library.
#
# Decisions baked in (user, 2026-10-11):
#   • no restore of the old compose stack — library starts empty and gets
#     filled by Google Takeout via immich-go (scripts/gphotos-import.sh)
#   • native systemd services for server + PostgreSQL + Redis (module-managed)
#   • transcode on the Cezanne iGPU (VAAPI); ML on the dGPU via the official
#     CUDA container (remote-ML URL), NOT the native ML service — the native
#     CUDA path needs an onnxruntime overlay fight; remote-ML is the module's
#     supported escape hatch and reuses warden's docker (plan 12 §9)
{ config, lib, pkgs, ... }:
{
  services.immich = {
    enable = true;
    host = "0.0.0.0";    # tailnet-only exposure via firewall — warden runs no
                         # caddy (no CF token), so bind wide + gate with nft
                         # (2026-10-26); loopback bind made it unreachable
    port = 2283;
    mediaLocation = "/srv/immich";
    accelerationDevices = [ "/dev/dri" ];  # iGPU VAAPI for video transcode
    machine-learning.enable = false;       # remote ML container below
  };

  services.immich.environment.MACHINE_LEARNING_URL = "http://127.0.0.1:3003";
  # VAAPI access (verified missing live 2026-10-26): ffmpeg runs as `immich`,
  # but /dev/dri/renderD128 is root:render 0660 and `id immich` showed no
  # render membership — hw transcode would fail EACCES and silently fall back
  # to software. radeonsi_drv_video.so IS present in /run/opengl-driver, so
  # group membership is the only missing piece on the Cezanne iGPU.
  users.users.immich.extraGroups = [ "render" ];

  virtualisation.oci-containers.containers.immich-ml = {
    image = "ghcr.io/immich-app/immich-machine-learning:release-cuda";
    autoStart = true;
    ports = [ "127.0.0.1:3003:3003" ];
    environment = {
      NVIDIA_VISIBLE_DEVICES = "all";
      NVIDIA_DRIVER_CAPABILITIES = "compute,utility";
      # First CUDA inference builds a TensorRT-RTX engine, which can exceed
      # the 300 s unresponsive-worker kill (immich defaults it to 900 s on
      # ROCm for exactly this). Seen live 2026-10-26: TRT-RTX EP crash (CUDA
      # 719) during engine build → workers restarted → CUDA init failed
      # ("no CUDA-capable device") → silent CPU fallback. A container restart
      # recovers CUDA (NixOS oci-container units re-run podman, i.e. recreate).
      MACHINE_LEARNING_WORKER_TIMEOUT = "900";
    };
    volumes = [ "/var/lib/immich-ml:/cache" ];
    extraOptions = [
      "--device=nvidia.com/gpu=all"   # CDI — podman has no "nvidia" OCI runtime (2026-10-25)
      "--memory=3g"       # PLAN §11 cap — set ABOVE working set (ms.api lesson)
    ];
  };

  systemd.tmpfiles.rules = [
    "d /srv/immich 0750 immich immich -"
    "d /var/lib/immich-ml 0700 root root -"
  ];

  # nightly DB dump alongside the restic of /srv/immich (PLAN §0 backups).
  # mkDefault: modules/matrix/backup.nix owns the 02:30 window when present —
  # one pg-dump window per night, immich joins it.
  services.postgresqlBackup = {
    enable = true;
    startAt = lib.mkDefault "*-*-* 03:15:00";
    databases = [ "immich" ];
  };

  # tailnet-only reachability for the immich UI (no caddy on this host)
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 2283 ];
  # LAN-direct for fast uploads from same-network devices (home wifi):
  # http://<warden-LAN-IP>:2283 — bypasses the tunnel entirely
  networking.firewall.interfaces."end0".allowedTCPPorts = [ 2283 ];

  # ── Storage findings (verified live 2026-10-26) ──────────────────────────
  # • /srv is a nested btrfs subvol (`srv` under @) → NOT covered by the root
  #   snapper config; the media library doesn't multiply snapshots. compress
  #   zstd is fs-wide; immich's originals/thumbs compress fine, transcodes
  #   (already-compressed h264) are auto-skipped by btrfs's heuristics.
  # • /var/lib/immich-ml (906 MB today) is a pure model cache: regenerateable
  #   by deletion+re-download. Do NOT add it to restic when the /srv/immich
  #   backup lands (PLAN §0 → eez156). NOTE: only restic-backups-matrix
  #   exists today — media restic is still an open item.
  # • External library unused by design: the Takeout import goes through
  #   immich-go's upload API (copies into mediaLocation). Storage template is
  #   already enabled in the DB (system-config row stores it).

  # ── Post-deploy admin-UI settings (DB-stored; nix can't own them without
  #    IMMICH_CONFIG_FILE, which would freeze the UI — not worth it):
  # 1. Video transcoding → acceleration: VAAPI, device /dev/dri/renderD128.
  #    Needs the render-group fix above; jellyfin-ffmpeg (VA-API capable) is
  #    already in the package closure. Verify: trigger a transcode, then
  #    `journalctl -u immich-server | grep -iE 'vaapi|falling back'` shows no
  #    software fallback.
  # 2. Jobs (5800H = 16 threads, ML on the 3050): thumbnails 3 → 5 (docs:
  #    keep ≤ core count); keep smartSearch 2 / faceDetection 2 (4 GB VRAM
  #    shared with speaches, and facial-recognition clustering is sequential
  #    regardless); videoConversion stays 1 until VAAPI is verified, 2 after.
  #    Defaults today are all stock (system-config row is sparse).
}
