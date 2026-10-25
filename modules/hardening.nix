# Fleet hardening baseline (live audit 2026-10-26, branch `hardening`).
# Imported by every DEPLOYED NixOS host (warden, artificer-nixos); scout-asahi
# adds it when it lands. Everything is mkDefault — any host overrides with a
# plain assignment.
#
# What the audit found and this module fixes:
#   • `sshd -T` on both hosts: PasswordAuthentication no, BUT
#     KbdInteractiveAuthentication yes with UsePAM yes — PAM keyboard-
#     interactive prompts can still accept account passwords. On warden,
#     wyli HAS a yescrypt password (/etc/nix/warden-passwd, console/sudo),
#     so password SSH login was effectively open despite the "key-only"
#     intent. KbdInteractiveAuthentication=false closes it.
#   • journald had NO size cap (137.7M warden / 64.1M pi, unbounded).
#     SystemMaxUse/SystemKeepFree bound it so a chatty unit can never fill
#     / — especially the pi's 58G SD card.
#
# Deliberately NOT changed here (decisions, not oversights):
#   • sudo stays NOPASSWD (security.sudo.wheelNeedsPassword = false on both
#     hosts): headless bring-up left no password infrastructure; passwords,
#     sudo prompts, AND the sops-nix secret store all land together with
#     plan 03 (nix-migration/03-multi-machine-flake.md). Command-list sudo
#     before secrets exist would only break rebuilds. Do NOT "fix" this
#     piecemeal — see hosts/*/default.nix.
#   • tailscale0 stays a trusted interface: tailscaled's own ts-input chain
#     ACCEPTs all tailscale0 traffic BEFORE the nixos-fw chain runs, so
#     "explicit port lists" would be dead config, not defense. The trust
#     boundary is the tailnet itself (device auth + ACLs, Tailscale console).
#   • sshd ciphers/MACs/KexAlgorithms are NOT pinned: the live sets
#     (chacha20/aes-gcm, hmac-sha2-*-etm, mlkem768x25519 kex) are already
#     the OpenSSH upstream defaults; pinning them would freeze today's
#     defaults and block tomorrow's rotations.
{ lib, ... }:
{
  services.openssh.settings = {
    # Key-only for real: without KbdInteractiveAuthentication=false, PAM
    # keyboard-interactive can still prompt for account passwords.
    PasswordAuthentication = lib.mkDefault false;
    KbdInteractiveAuthentication = lib.mkDefault false;
    PermitRootLogin = lib.mkDefault "prohibit-password"; # keys only
  };

  # NOTE: extraConfig is one merged string — a host override must repeat
  # these lines if it wants to keep them.
  services.journald.extraConfig = lib.mkDefault ''
    SystemMaxUse=2G
    SystemKeepFree=4G
  '';
}
