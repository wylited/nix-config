# modules/whisper.nix — plan 12 §8: speaches (faster-whisper server) on the
# RTX 3050 + GPU Mode B bring-up (flips plan 08's "Mode A headless").
#
# GPU: compute-only — amdgpu stays the display path, the dGPU never modesets,
# RTD3 fine-grained power management keeps it at ~0 W idle and wakes it on
# demand (<1 s). Speaches and immich-ML share the 4 GB (PLAN §11 VRAM note).
#
# TODO (before deploy, PLAN §12 #4): confirm the exact speaches CUDA image tag
# and env-key spelling (viper: SPEACHES__SECTION__KEY) against the current
# README — the project renamed its env vars when it forked from
# faster-whisper-server; model key below is the intended value.
{ config, lib, pkgs, ... }:
{
  # ---------------- GPU Mode B ----------------
  services.xserver.videoDrivers = [ "amdgpu" "nvidia" ];
  # 32-bit GL: hard requirement of the nvidia module for enableNvidia on x86_64
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;  # Ampere
    modesetting.enable = false;        # compute only — no display on the dGPU
    nvidiaSettings = false;
    open = false;                      # GA107 mobile: open module GSP-RPC timeouts (verified on-box 2026-10-25); closed module works
    powerManagement.enable = true;
    powerManagement.finegrained = true;  # RTD3 (~0 W idle, wakes on demand)
    # module assertion: finegrained ⇒ offload — headless, but the plumbing
    # costs nothing and the bus IDs are from the 2026-08-23 warden capture
    prime = {
      offload.enable = true;
      amdgpuBusId = "PCI:4:0:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };
  # container GPU access (speaches + immich-ml run as CUDA containers)
  hardware.nvidia-container-toolkit.enable = true;

  # ---------------- speaches ----------------
  virtualisation.oci-containers.containers.speaches = {
    image = "ghcr.io/speaches-ai/speaches:latest-cuda";
    autoStart = true;
    ports = [ "127.0.0.1:8000:8000" ];
    environment = {
      # verified against the image's config.py (2026-10-25): pydantic-settings
      # with env_nested_delimiter="__" and NO prefix — WHISPER__FIELD, not
      # SPEACHES__WHISPER__FIELD. No model field exists anymore: models load
      # CPU since 2026-10-26: the 3050 is hardware-dead (reset-required survives
      # battery-disconnect drain; Xid 119 GSP timeouts at every init). ~realtime
      # on the 5800H for large-v3. Flip back to cuda if the card is ever revived.
      WHISPER__INFERENCE_DEVICE = "cpu";
      WHISPER__COMPUTE_TYPE = "int8_float16";
      WHISPER__TTL = "-1";
      NVIDIA_VISIBLE_DEVICES = "all";
      NVIDIA_DRIVER_CAPABILITIES = "compute,utility";
    };
    volumes = [
      "/var/lib/speaches:/root/.cache/huggingface"   # model cache survives pulls
    ];


    extraOptions = [
      "--device=nvidia.com/gpu=all"  # CDI — podman has no "nvidia" OCI runtime (2026-10-25)
      "--memory=3g"      # PLAN §11
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/speaches 0700 root root -"
  ];

  # tailnet-only reachability for speaches (no caddy on this host)
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8000 ];
}
