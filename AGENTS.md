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
- **Guards (2026-11-18)**: `.mailmap` folds 13 historical commits with stray
  addresses (`wyli@wyli.tech`, `wyli@warden`, …) onto the canonical identity at
  display time — history was already public, so it is NOT rewritten.
  `.githooks/pre-commit` refuses a commit whose name/email or
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` differ from the canonical pair; CI's
  `commit identity is wylited` step fails the same way. The hook only runs
  where `core.hooksPath=.githooks` is set — clones made by hand need
  `git config core.hooksPath .githooks` once.

## Deploy runbook (read before ANY rebuild)

- **warden deploys**: `config/scripts/fleet-deploy.sh warden` from the Mac (the script implements warden only). Push the commit from the Mac first. The script pulls the target checkout and rebuilds; don't hand-roll remote rebuild commands. It trusts origin/main: that content becomes root via `sudo -n nixos-rebuild`, with no signature check — treat repo write access as root on warden.
- **warden**: the git remote is **HTTPS and pull-only**. The checkout at `/home/wyli/Repos/nix-config` fetches with `git pull --ff-only`; commits and pushes happen on the Mac only. **Never push from warden**, never rebase there, and NEVER `reset --hard` (wiped unpushed agent commits twice, 2026-10-26). `--impure` is load-bearing (pathExists guards — see hosts/warden/default.nix header).
- **dsh (web agent on warden)**: since the 2026-11-18 audit it is a *low-privilege* workspace agent, not a deploy path. It has no docker group, no `nix trusted-users`, no SSH key on `wyli`, no GitHub deploy key and no `gh` token; `ds.ts.wyli.tech` is behind Caddy `basic_auth` **for non-tailnet clients only** — tailnet requests pass through by owner decision (the tailnet is the trust domain); password: warden `/etc/nix/dsh-web-password`, 0600. Its self-update pulls the fork's `wyli` branch hourly as root, so **any push to that branch deploys as root within the hour — publish from the Mac only**. Fleet work (`nixos-rebuild`, `fleet-deploy.sh`, secret changes) runs from a local interactive agent on the Mac over `ssh warden`.
- **Tailnet is the access path**: `ssh warden` authenticates via Tailscale SSH (node identity), not SSH keys — the Mac key is passphrase-protected and normally not in the agent. The tailnet SSHPolicy accepts `wyli` and `root` from every node, so any tailnet device is root on the fleet; treat device auth as root auth. Next step: load the Mac key (`ssh-add --apple-use-keychain ~/.ssh/wyli`), then `tailscale set --ssh=false` per host. Never leave a Tailscale Funnel configured; the `tailnet-funnel-guard` unit resets one at boot.
- **scout-darwin (Mac)**: the repo flake is the source of truth — `nix build ~/research/homelab/config#darwinConfigurations.scout-darwin.system` then `sudo darwin-rebuild switch --flake ~/research/homelab/config#scout-darwin`. `darwin-update` wraps the switch and pins that flake. `/etc/nix-darwin` is a legacy fork being retired; never edit or switch against it.
- **warden + any NEW fetchurl in the tree**: add `--option builders '' --option max-jobs 4`. The default remote builder (eez156) cannot fetch some upstreams (github raw 404s from its egress) — the failure surfaces as a bare `Cannot build` with the real error only in `nix log <drv>`. (Old "warden pins max-jobs=0" note is stale: live `/etc/nix/nix.conf` is `max-jobs = auto`.) If a switch says "Cannot build", build the named drv standalone and read its log.
- **artificer (pi)**: ONLINE on the tailnet (`artificer-nixos`, direct LAN path). It was never offline — `Permission denied (publickey)` only means the Mac's passphrase-protected key is not in ssh-agent. Access it with Tailscale SSH (`ssh pi`); load the key (`ssh-add --apple-use-keychain ~/.ssh/wyli`) if you need OpenSSH. Config changes: `rsync -a --delete --exclude .git ~/research/homelab/config/ wyli@100.95.249.82:homelab/nix-config/` then ssh + `nixos-rebuild switch --flake ~/homelab/nix-config#artificer-nixos`. Remote shells are fish — pipe compound bash via `cat <<'EOF' | ssh … bash`; sudo lives at `/run/wrappers/bin/sudo` (not on the default PATH of piped shells).
- **Eval floor before every push**: `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath --impure > /tmp/e 2>&1; echo $?` — capture to a file and check the EXIT CODE; piping eval through `tail` masks failures (burned twice). CI (`.github/workflows/ci.yml`) evals artificer + scout-darwin toplevels and runs `nix flake check --no-build`, which also evaluates warden under pure eval.
- **Fleet docs live OUTSIDE the repo**: `~/research/homelab/README.md` (runbooks, service table) + `PLAN.md` (decision history) + `ARCHITECTURE.md` (plain-language map). Keep them in sync with big changes.
- Host-side secrets (never in the repo): warden `/etc/nix/{warden-passwd,
  attic-token.txt, ai-env (ZAI+LITHOSAI), acme-desec-env (deSEC DNS-01),
  dsh-env, ecemaker_build_ed25519, immich-backup_ed25519}` and
  `/var/lib/sure/sure.env`; artificer `/etc/nix/restic-password*` when backups
  are enabled. Never paste a secret into `environment.etc.*.text` — it lands
  world-readable in the store; generate it from the host file at activation
  (see `modules/lab-cache.nix`).
  (Matrix-era secrets died with the 2026-11-08 teardown; radicale-htpasswd
  deleted 2026-11-09 — radicale is passwordless, tailnet is the boundary.)

## Fleet hardening baseline

- `modules/hardening.nix` (imported by deployed hosts, 2026-10-26 audit) owns
  the sshd baseline (key-only: no password AND no PAM keyboard-interactive)
  and journald size caps. All mkDefault — hosts override with plain values.
- `security.sudo.wheelNeedsPassword = false` on warden/artificer is
  DELIBERATE: no password infrastructure exists. Don't piecemeal it.
- tailscale0 stays trusted: tailscaled's ts-input chain accepts tailnet
  traffic before nixos-fw sees it — explicit port lists would be dead config.
