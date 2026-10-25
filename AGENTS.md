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
