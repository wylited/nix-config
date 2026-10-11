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
    host = "127.0.0.1";
    port = 2283;
    mediaLocation = "/srv/immich";
    accelerationDevices = [ "/dev/dri" ];  # iGPU VAAPI for video transcode
    machine-learning.enable = false;       # remote ML container below
  };

  services.immich.environment.MACHINE_LEARNING_URL = "http://127.0.0.1:3003";

  virtualisation.oci-containers.containers.immich-ml = {
    image = "ghcr.io/immich-app/immich-machine-learning:release-cuda";
    autoStart = true;
    ports = [ "127.0.0.1:3003:3003" ];
    environment = {
      NVIDIA_VISIBLE_DEVICES = "all";
      NVIDIA_DRIVER_CAPABILITIES = "compute,utility";
    };
    volumes = [ "/var/lib/immich-ml:/cache" ];
    extraOptions = [
      "--runtime=nvidia"
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
}
