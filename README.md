# nix-config

NixOS/nix-darwin config for the wyli.tech homelab fleet: warden-arch
(main server), artificer-nixos (pi — DNS/CalDAV), scout-darwin (Mac).
Deploy with `nixos-rebuild`/`nix run nix-darwin` from this flake; see
AGENTS.md and PLAN.md for fleet context.

## CI

`.github/workflows/ci.yml` runs on every push and PR and is **eval-only**:

- `eval` job: evaluates the `artificer-nixos` and `scout-darwin` toplevels
  (`nix eval …drvPath`) — catches flake/module breakage before deploy.
- `flake-check` job: `nix flake check --no-build`.

Not covered, deliberately:

- **warden is never built or explicitly eval'd in the matrix.** Its config
  guards live-host state with `pathExists` (see hosts/warden/default.nix);
  those guards no-op under pure eval, so `flake check` still passes, but the
  resulting eval is not the deployed config and building it needs secrets /
  host paths public runners don't have.
- No builds of any toplevel, no deploy, no secrets — runners are stateless
  public machines with no ssh keys and no tailscale access.
