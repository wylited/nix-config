# AGENTS.md

## Git identity — hard rule

Commit as `wylited <44154103+wylited@users.noreply.github.com>`. That noreply
email is the ONLY one GitHub links to the wylited account.

- Identity is already configured everywhere: system gitconfig on every NixOS
  host (`modules/git.nix` → /etc/gitconfig) and the Mac's global `~/.gitconfig`.
  Just `git add` + `git commit` — nothing else.
- NEVER pass `-c user.name=…` / `-c user.email=…` / `--author=…` / `GIT_AUTHOR_*`
  or `GIT_COMMITTER_*` env vars. A 2026-10 drift where agent sessions committed
  as `wyli <wyli@wyli.tech>` required a full history rewrite + force-push.
- `wyli@wyli.tech` is the ACME/ingress email (`modules/ingress.nix`) — it is
  NOT a commit identity. Never use it in git.
- Message style: `<host-or-scope>: summary` (see `git log`).

## Fleet hardening baseline

- `modules/hardening.nix` (imported by deployed hosts, 2026-10-26 audit) owns
  the sshd baseline (key-only: no password AND no PAM keyboard-interactive)
  and journald size caps. All mkDefault — hosts override with plain values.
- `security.sudo.wheelNeedsPassword = false` on warden/artificer is
  DELIBERATE until plan 03 (sops-nix) lands: no password infrastructure
  exists yet; sudo + secrets tighten together. Don't piecemeal it.
- tailscale0 stays trusted: tailscaled's ts-input chain accepts tailnet
  traffic before nixos-fw sees it — explicit port lists would be dead config.
