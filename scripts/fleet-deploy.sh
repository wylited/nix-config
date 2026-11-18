#!/usr/bin/env bash
# fleet-deploy.sh — measured NixOS deploy from the Mac.
#
# The Mac worktree is the source of truth for *evaluation*, but the target host
# builds from its own checkout of origin/main. So a deploy is:
#   1. Mac preflight: on main, clean, FF-able to origin/main, eval floor passes
#   2. warden: fetch + `git merge --ff-only origin/main` (never rebase/reset)
#   3. warden: `nixos-rebuild switch --flake path:<repo>#warden --impure`
#   4. post-check: /run/current-system == the toplevel warden evaluated itself
#
# Expected toplevel is computed ON WARDEN (as root, with --impure): warden's
# config has pathExists guards on /etc/nix/* secrets that do not exist on the
# Mac, so the Mac-side eval yields a different store path by design. The Mac
# eval floor is a buildability gate, not the expected output.
#
# Usage: fleet-deploy.sh <host> [--check|--dry-run]
#   --check     report drift only (Mac main vs origin, warden HEAD vs origin,
#               warden current-system vs freshly evaluated toplevel); exit 1
#               on drift. Never merges, never rebuilds.
#   --dry-run   do everything except the switch.
set -euo pipefail

HOST=""
MODE="deploy"

usage() {
  cat <<'USAGE'
Usage: fleet-deploy.sh <host> [--check|--dry-run]

  host        warden (the only supported host)
  --check     report drift only; exit 1 when the host is not at origin/main or
              its running system differs from a fresh eval
  --dry-run   run every step except `nixos-rebuild switch`

No activation happens unless neither --check nor --dry-run is given.
USAGE
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --check)   [ "$MODE" = deploy ] || die "only one of --check/--dry-run may be given"; MODE="check" ;;
    --dry-run) [ "$MODE" = deploy ] || die "only one of --check/--dry-run may be given"; MODE="dry-run" ;;
    -h|--help) usage; exit 0 ;;
    -*)        printf 'error: unknown option %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$HOST" ] || { printf 'error: unexpected argument %s\n\n' "$arg" >&2; usage >&2; exit 2; }
      HOST="$arg"
      ;;
  esac
done

[ -n "$HOST" ] || { usage >&2; exit 2; }
[ "$HOST" = warden ] || die "unsupported host '$HOST' (only 'warden' is implemented)"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REMOTE_REPO=/home/wyli/Repos/nix-config
FLAKE_BASE="path:$REMOTE_REPO"
# nixos-rebuild accepts the shorthand '#warden'; nix eval needs the full attr path.
FLAKE_REF="$FLAKE_BASE#warden"
EVAL_ATTR=nixosConfigurations.warden.config.system.build.toplevel.outPath
# Default is the Mac's alias. The dsh service on warden has no MagicDNS name
# for `warden`; it runs this with FLEET_SSH_TARGET=wyli@100.68.142.0.
SSH_TARGET=${FLEET_SSH_TARGET:-warden}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$SSH_TARGET")

TMPDIR_DEPLOY=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DEPLOY"' EXIT

# Run a bash snippet on warden; stdin is the script. Remote login shell is fish,
# so never send compound commands as a one-liner.
remote() { "${SSH[@]}" bash -s; }

# Capture stdout of a remote bash snippet; caller handles failure.
remote_out() {
  local err="$TMPDIR_DEPLOY/remote.err"
  remote 2>"$err"
}

step()  { printf '\n==> %s\n' "$*"; }
ok()    { printf '  ok    %s\n' "$*"; }
warn()  { printf '  WARN  %s\n' "$*" >&2; }
drift() { printf '  DRIFT %s\n' "$*"; }

cd "$REPO_ROOT"

DRIFT=0
DRIFT_NOTES=""

note_drift() { DRIFT=1; DRIFT_NOTES="$DRIFT_NOTES  - $1"$'\n'; drift "$1"; }

# ---------------------------------------------------------------------------
# Local preflight
# ---------------------------------------------------------------------------
step "local preflight ($REPO_ROOT)"

BRANCH=$(git branch --show-current)
if [ "$BRANCH" != main ]; then
  die "not on 'main' (currently '${BRANCH:-detached HEAD}'); deploys must come from main"
fi

git fetch --quiet origin || die "git fetch origin failed"

LOCAL_MAIN=$(git rev-parse main)
ORIGIN_MAIN=$(git rev-parse origin/main)
echo "  local main   $LOCAL_MAIN"
echo "  origin/main  $ORIGIN_MAIN"

if [ "$LOCAL_MAIN" != "$ORIGIN_MAIN" ]; then
  if [ "$MODE" = check ]; then
    note_drift "local main ($LOCAL_MAIN) != origin/main ($ORIGIN_MAIN)"
  else
    die "local main is not origin/main (diverged or behind). Refusing to deploy stale/unpublished code.
       local  $LOCAL_MAIN
       origin $ORIGIN_MAIN
     Rebase/merge is a human decision: run 'git pull --ff-only origin main' (or push) first."
  fi
else
  ok "local main == origin/main"
fi

# Untracked files do not affect a git-flake eval, and this script itself may be
# untracked; only tracked modifications matter.
DIRTY=$(git status --porcelain --untracked-files=no)
if [ -n "$DIRTY" ]; then
  if [ "$MODE" = deploy ] || [ "$MODE" = dry-run ]; then
    die "worktree has uncommitted tracked changes; a deploy must be measured from a committed tree:
$DIRTY
     Commit or stash them first (the dry-run is a rehearsal of the real deploy, so it refuses too)."
  fi
  warn "worktree has uncommitted tracked changes (not counted as fleet drift):"
  printf '%s\n' "$DIRTY" | sed 's/^/        /' >&2
else
  ok "worktree clean (tracked files)"
fi

# Eval floor: stdout to a file, decide on the EXIT CODE (piping through tail has
# masked eval failures on this fleet before). Always --impure: pathExists guards.
step "eval floor: nixosConfigurations.$HOST toplevel.drvPath"
DRV_FILE="$TMPDIR_DEPLOY/drv"
EVAL_ERR="$TMPDIR_DEPLOY/eval.err"
set +e
nix eval --raw ".#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath" --impure --no-write-lock-file \
  >"$DRV_FILE" 2>"$EVAL_ERR"
EVAL_RC=$?
set -e
if [ "$EVAL_RC" -ne 0 ]; then
  echo "  eval failed (exit $EVAL_RC):" >&2
  sed -n '1,25p' "$EVAL_ERR" >&2
  if [ "$MODE" = check ]; then
    note_drift "eval floor failed (exit $EVAL_RC) on the Mac"
  else
    die "eval floor failed (exit $EVAL_RC); nothing was changed on $HOST"
  fi
else
  DRV=$(cat "$DRV_FILE")
  case "$DRV" in
    /nix/store/*.drv) ok "drvPath $DRV" ;;
    *) die "eval floor produced unexpected output: '$DRV'" ;;
  esac
fi

# ---------------------------------------------------------------------------
# warden: fetch (and, for a real deploy, fast-forward)
# ---------------------------------------------------------------------------
step "warden: fetch origin"
if ! OUT=$(remote_out <<EOF
set -e
cd $REMOTE_REPO
git fetch --quiet origin
EOF
); then
  die "warden: git fetch origin failed:
$(cat "$TMPDIR_DEPLOY/remote.err")"
fi
ok "fetched"

REMOTE_HEAD=$(remote <<EOF
set -e
cd $REMOTE_REPO
git rev-parse HEAD
EOF
) || die "warden: ssh failed while reading HEAD: $(cat "$TMPDIR_DEPLOY/remote.err")"
REMOTE_ORIGIN=$(remote <<EOF
set -e
cd $REMOTE_REPO
git rev-parse origin/main
EOF
) || die "warden: ssh failed while reading origin/main: $(cat "$TMPDIR_DEPLOY/remote.err")"
echo "  warden HEAD  $REMOTE_HEAD"
echo "  origin/main  $REMOTE_ORIGIN"

if [ "$REMOTE_HEAD" != "$REMOTE_ORIGIN" ]; then
  if [ "$MODE" = check ]; then
    note_drift "warden HEAD ($REMOTE_HEAD) != origin/main ($REMOTE_ORIGIN)"
  fi
fi

REMOTE_DIRTY=$(remote <<EOF
set -e
cd $REMOTE_REPO
git status --porcelain --untracked-files=no
EOF
)
if [ -n "$REMOTE_DIRTY" ]; then
  if [ "$MODE" = check ]; then
    note_drift "warden checkout has uncommitted tracked changes:
$REMOTE_DIRTY"
  else
    die "warden checkout has uncommitted tracked changes; refusing to merge over them:
$REMOTE_DIRTY"
  fi
fi

if [ "$MODE" != check ]; then
  step "warden: fast-forward to origin/main"
  if ! OUT=$(remote_out <<EOF
set -e
cd $REMOTE_REPO
git merge --ff-only origin/main
EOF
); then
  die "warden: 'git merge --ff-only origin/main' failed — the host diverged from origin/main.
     Nothing was reset or rebased. Investigate manually; do NOT 'git reset --hard' (it has
     destroyed unpushed work twice). Output:
$(cat "$TMPDIR_DEPLOY/remote.err")"
  fi
  printf '%s\n' "$OUT" | sed 's/^/  /'
  REMOTE_HEAD=$(remote <<EOF
set -e
cd $REMOTE_REPO
git rev-parse HEAD
EOF
)
  [ "$REMOTE_HEAD" = "$ORIGIN_MAIN" ] || die "warden HEAD ($REMOTE_HEAD) is not origin/main ($ORIGIN_MAIN) after fast-forward"
  ok "warden at $REMOTE_HEAD"
fi

# ---------------------------------------------------------------------------
# Host state: running generation and the expected toplevel
# ---------------------------------------------------------------------------
step "warden: current generation"
CURRENT=$(remote_out <<'EOF'
set -e
readlink /run/current-system
EOF
) || die "ssh failed while reading /run/current-system on warden: $(cat "$TMPDIR_DEPLOY/remote.err")"
[ -n "$CURRENT" ] || die "could not read /run/current-system on warden"
echo "  current  $CURRENT"

step "warden: evaluating expected toplevel (root, --impure)"
EXPECTED_FILE="$TMPDIR_DEPLOY/expected"
EXP_ERR="$TMPDIR_DEPLOY/expected.err"
set +e
remote >"$EXPECTED_FILE" 2>"$EXP_ERR" <<EOF
set -e
sudo -n nix eval --raw "$FLAKE_BASE#$EVAL_ATTR" --impure --no-write-lock-file
EOF
EXP_RC=$?
set -e
if [ "$EXP_RC" -ne 0 ]; then
  echo "  expected-toplevel eval failed (exit $EXP_RC):" >&2
  sed -n '1,25p' "$EXP_ERR" >&2
  if [ "$MODE" = check ]; then
    note_drift "could not evaluate the expected toplevel on warden (exit $EXP_RC)"
  else
    die "could not evaluate the expected toplevel on warden (exit $EXP_RC)"
  fi
  EXPECTED=""
else
  EXPECTED=$(cat "$EXPECTED_FILE")
  case "$EXPECTED" in
    /nix/store/*-nixos-system-*) ok "expected $EXPECTED" ;;
    *) die "unexpected toplevel path from warden: '$EXPECTED'" ;;
  esac
fi

if [ -n "$EXPECTED" ]; then
  if [ "$CURRENT" = "$EXPECTED" ]; then
    ok "running system already matches origin/main"
  elif [ "$MODE" = check ]; then
    note_drift "warden /run/current-system ($CURRENT) != expected ($EXPECTED)"
  else
    echo "  drift    running system is behind origin/main (expected $EXPECTED)"
  fi
fi

if [ "$MODE" = check ]; then
  if [ "$DRIFT" -ne 0 ]; then
    step "check: drift detected"
    printf '%s' "$DRIFT_NOTES"
    exit 1
  fi
  step "check: no drift"
  exit 0
fi

if [ "$MODE" = dry-run ]; then
  step "dry-run: skipping activation"
  echo "  would run: ssh warden 'sudo -n nixos-rebuild switch --flake $FLAKE_REF --impure'"
  exit 0
fi

# ---------------------------------------------------------------------------
# Activate
# ---------------------------------------------------------------------------
step "warden: nixos-rebuild switch"
set +e
remote <<EOF
set -e
sudo -n nixos-rebuild switch --flake "$FLAKE_REF" --impure --no-write-lock-file
EOF
SWITCH_RC=$?
set -e
if [ "$SWITCH_RC" -ne 0 ]; then
  # sshd is among the units the switch restarts, so a dropped connection
  # (ssh exit 255) is expected even when activation succeeded: systemd-run
  # keeps it going. Any other exit is a real failure.
  if [ "$SWITCH_RC" -ne 255 ]; then
    printf '\n' >&2
    echo "  switch failed (exit $SWITCH_RC); the previous generation is still booted." >&2
    echo "  rollback: ssh warden 'sudo nixos-rebuild switch --rollback'" >&2
    exit 1
  fi
  echo "  ssh closed during activation; waiting for the new generation..."
  SWITCH_OK=0
  for _ in $(seq 1 90); do
    sleep 2
    if NOW=$(remote_out <<'EOF'
set -e
readlink /run/current-system
EOF
); then
      if [ "$NOW" = "$EXPECTED" ]; then
        SWITCH_OK=1
        break
      fi
    fi
  done
  if [ "$SWITCH_OK" -ne 1 ]; then
    echo "  activation did not reach $EXPECTED within 180s" >&2
    echo "  rollback: ssh warden 'sudo nixos-rebuild switch --rollback'" >&2
    exit 1
  fi
  ok "activation completed after reconnect"
fi

# ---------------------------------------------------------------------------
# Post-check
# ---------------------------------------------------------------------------
step "post-check"
AFTER=$(remote_out <<'EOF'
set -e
readlink /run/current-system
EOF
) || die "post-check ssh failed: $(cat "$TMPDIR_DEPLOY/remote.err")"
echo "  before   $CURRENT"
echo "  after    $AFTER"
if [ "$AFTER" = "$EXPECTED" ]; then
  ok "running system matches the evaluated toplevel"
else
  echo "  MISMATCH: expected $EXPECTED" >&2
  echo "  rollback: ssh warden 'sudo nixos-rebuild switch --rollback'" >&2
  exit 1
fi

step "done"
echo "  rollback (if ever needed): ssh warden 'sudo nixos-rebuild switch --rollback'"
