# modules/whisper.nix — speaches (faster-whisper server), CPU-only.
#
# The RTX 3050 died 2026-10-26 (Xid 119 GSP timeouts, survives full power
# drain — hardware, not config). All nvidia plumbing is gone; the container
# runs the CUDA image in CPU mode (WHISPER__COMPUTE_TYPE=int8) on the 5800H,
# ≈2–2.5× realtime for large-v3. Flip back to a CUDA compute type only with a
# working card — and re-add hardware.nvidia with it.
{ config, lib, pkgs, ... }:
{
  services.xserver.videoDrivers = [ "amdgpu" ];
  hardware.graphics.enable = true;

  virtualisation.oci-containers.containers.speaches = {
    image = "ghcr.io/speaches-ai/speaches:latest-cuda";
    autoStart = true;
    ports = [ "8000:8000" ];   # all interfaces — the firewall line below is the gate (was loopback-only: tailnet clients got conn-refused)
    environment = {
      # verified against the image's config.py (2026-10-25): pydantic-settings
      # with env_nested_delimiter="__" and NO prefix — WHISPER__FIELD, not
      # SPEACHES__WHISPER__FIELD. No model field exists anymore: models load
      # CPU since 2026-10-26: the 3050 is hardware-dead (reset-required survives
      # battery-disconnect drain; Xid 119 GSP timeouts at every init). ~realtime
      # on the 5800H for large-v3. Flip back to cuda if the card is ever revived.
      WHISPER__COMPUTE_TYPE = "int8";   # int8_float16 needs GPU; int8 = CPU (CT2 ValueError otherwise)
      WHISPER__TTL = "-1";
      # (GPU env removed with the dead card — CPU-only container now)
    };
    volumes = [
      "/var/lib/speaches:/root/.cache/huggingface"   # model cache survives pulls
    ];

    extraOptions = [
      "--memory=3g"      # PLAN §11
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/speaches 0700 root root -"
  ];

  # speaches drops its installed-model registry on every container restart
  # (HF cache survives; the install does not). Re-register large-v3 per start —
  # cache hit, so seconds not a download.
  systemd.services.speaches-preload = {
    description = "register whisper large-v3 in speaches (cached)";
    after = [ "podman-speaches.service" ];
    partOf = [ "podman-speaches.service" ];
    wantedBy = [ "multi-user.target" ];
    # Never inside the activation transaction: switch-to-configuration restarts
    # changed units and waits, and PartOf=podman-speaches drags this oneshot
    # into every switch that recreates the container — where the /health wait
    # expires while the image re-pulls and the failed job turned the whole
    # switch into exit 4 (2026-10-26 03:17, exactly 60×5s wall). The PartOf
    # propagation still re-runs the unit (post-daemon-reload, i.e. the current
    # script) on every container restart, so registration still tracks the
    # container.
    restartIfChanged = false;
    serviceConfig.Type = "oneshot";
    serviceConfig.ExecStart = toString (pkgs.writeShellScript "speaches-preload" ''
      CURL=${pkgs.curl}/bin/curl
      # 10 min, not 5: an image re-pull alone outlasted the old 60×5s loop
      # (this runs in the background via PartOf — it does not block switches).
      for i in $(seq 1 120); do
        $CURL -sf -m 4 http://127.0.0.1:8000/health >/dev/null 2>&1 && break
        sleep 5
      done
      exec $CURL -sf -X POST -m 600 \
        http://127.0.0.1:8000/v1/models/Systran%2Ffaster-whisper-large-v3
    '');
  };

  # tailnet-only reachability for speaches (no caddy on this host)
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8000 ];
  networking.firewall.interfaces."end0".allowedTCPPorts = [ 8000 ];  # LAN-direct, same pattern as immich
}
