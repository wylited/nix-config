# Fleet secrets base — sops-nix (plan 03; runbook: PLAN.md §14).
#
# STATE (2026-10-26): infrastructure only, ZERO secrets migrated. Every host
# still reads its ad-hoc files — warden: /etc/nix/{warden-passwd,
# attic-token.txt, ai-env, acme-desec-env}, artificer: /etc/nix/radicale-htpasswd;
# /var/lib/matrix-secrets/* on warden stays host-side by decision (PLAN §0 /
# plan 10 §5.4: host-originated must-stay-stable values never leave the box).
# sops.defaultSopsFile stays null: with no sops.secrets defined, sops-nix
# materializes nothing under /run/secrets. The only deploy-time effect of this
# module is the one-shot generation of /var/lib/sops-nix/key ("generation 0"
# in the runbook) — no service reads it yet.
#
# KEY STRATEGY — age, one key per host, generated on the host (NOT the ssh
# host keys that sops-nix would pick up by default):
#   1. scout-darwin has no sshd host keys; a dedicated age key is the one
#      story that works fleet-wide.
#   2. Independent lifecycle: rotating/reinstalling ssh host keys (hardware
#      swap, security regen) cannot silently break decryption. The age key
#      lives in /var/lib — same rule as matrix-secrets: stable, root-only,
#      survives service reinstalls.
#   3. Ops simplicity: the pubkey is printed inside the key file itself
#      (grep age1 /var/lib/sops-nix/key) or via `age-keygen -y`; no
#      ssh-to-age conversion roundtrip.
#   generateKey = true makes first deploy self-provisioning: activation runs
#   age-keygen iff the key file is missing (0600, root-only).
#   sshKeyPaths = [] pins a SINGLE key source per host — one entry per host
#   in .sops.yaml creation_rules, no silent host-key fallback that would rot
#   the day an ssh key rotates.
#
# MIGRATION (per-secret, incremental — pilot: attic-token on warden, §14):
#   1. generation-0 deploy of this module already generated the host keys.
#   2. collect each host's pubkey, write .sops.yaml creation_rules.
#   3. `sops` the value into hosts/<host>/secrets.yaml (ciphertext is
#      committed — that's the point), then in the host config:
#        sops.defaultSopsFile = ./secrets.yaml;
#        sops.secrets.<name> = { };
#   4. point the consumer at /run/secrets/<name>, keep the old /etc/nix
#      path as fallback until confidence, then delete the ad-hoc file.
{ ... }:

{
  sops = {
    # No secrets file exists yet — first one lands with the pilot (§14).
    defaultSopsFile = null;

    age = {
      keyFile = "/var/lib/sops-nix/key";
      generateKey = true;
      sshKeyPaths = [ ];
    };
  };
}
