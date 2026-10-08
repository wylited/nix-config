#!/usr/bin/env bash
# Throwaway: every shell script the warden matrix stack renders must parse.
set -uo pipefail
cd "$(dirname "$0")"
units=(matrix-healthcheck matrix-secrets matrix-tailscale-serve nixos-upgrade
       mautrix-whatsapp-registration mautrix-instagram-registration
       mautrix-discord-registration restic-backups-matrix postgresqlBackup-matrix-synapse)
fail=0
for u in "${units[@]}"; do
  for attr in script preStart postStart preStop ExecStartPre; do
    out=$(nix eval --raw ".#nixosConfigurations.warden.config.systemd.services.$u.$attr" 2>/dev/null) || continue
    [ -n "$out" ] || continue
    # ExecStartPre entries are argv lists; only check things that look like shell
    if printf '%s' "$out" | grep -qE '^\s*(#!|set |echo|if |systemctl|/nix/store)'; then
      printf '%s' "$out" > "/tmp/check-$u-$attr.sh"
      if bash -n "/tmp/check-$u-$attr.sh" 2>/tmp/check-err; then
        echo "ok   $u.$attr"
      else
        echo "FAIL $u.$attr: $(head -1 /tmp/check-err)"; fail=1
      fi
    fi
  done
done
exit $fail
