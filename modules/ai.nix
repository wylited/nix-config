# modules/ai.nix — pi (dev agent) + aichat (quick chat) on a host.
# Decisions locked with wyli 2026-10-26:
#   • MCP-FIRST: pi's native MCP (`pi mcp add`, per-profile mcp.json) is the
#     integration point. NO omp skills are copied — profiles start EMPTY and
#     you pick tools/MCP servers/skills per profile by hand. The old glm53-*
#     rules/extensions are NOT ported (broken upstream of omp too); rebuild
#     what actually matters as pi extensions when needed.
#   • Keys never in the repo: /etc/nix/ai-env (root:wheel 0640) holds
#     ZAI_API_KEY / DEEPSEEK_API_KEY; wrappers source it. Rotate freely —
#     nothing declarative references the values.
#   • Sessions/state are USER data: ~/.pi/agent (or per-profile dirs) and
#     ~/.config/aichat are never touched by nix. Nix ships binaries, wrappers,
#     and the aichat client config only.
#   • Profiles = one agent-dir each (~/.pi/profiles/<name>): own settings,
#     models.json, mcp.json, extensions, sessions. Create a profile dir, drop
#     files in, run `pip <name>` — that's the whole mechanism.
{ config, lib, pkgs, ... }:
let
  aiEnv = "/etc/nix/ai-env";
in
{
  environment.systemPackages =
    (with pkgs; [
      pi-coding-agent   # the agent (nixpkgs; `pi update` disabled under nix — update via flake)
      aichat            # quick chat: `aichat -m zai:glm-5.3-flash 'q'`
      tmux              # long sessions: ssh in, tmux attach, close the laptop
    ])
    ++ [
      # `pip <profile> [args…]` — run pi with an isolated agent dir.
      # Profile dirs are yours: ~/.pi/profiles/<name>/{settings.json,models.json,
      # mcp.json,extensions/,skills/,prompts/,sessions/}. Nothing is pre-created.
      (pkgs.writeShellScriptBin "pip" ''
        if [ $# -lt 1 ]; then
          echo "usage: pip <profile> [pi args…]" >&2
          echo "profiles live at ~/.pi/profiles/<name> (create them yourself)" >&2
          exit 1
        fi
        profile="$1"; shift
        export PI_CODING_AGENT_DIR="$HOME/.pi/profiles/$profile"
        set -a; [ -f ${aiEnv} ] && . ${aiEnv}; set +a
        exec ${pkgs.pi-coding-agent}/bin/pi "$@"
      '')
    ];

  # aichat: declarative client config, key via the shared env file.
  home-manager.users.wyli = {
    programs.aichat = {
      enable = true;
      settings = {
        model = "zai:glm-5.3-flash";
        save_session = true;
        clients = [
          {
            type = "openai-compatible";
            name = "zai";
            api_base = "https://api.z.ai/api/paas/v4";
            models = [
              { name = "glm-5.3"; }
              { name = "glm-5.3-flash"; }
            ];
          }
          {
            type = "openai-compatible";
            name = "lithosai";           # the actual DeepSeek-V4.1-Flash provider in use
            api_base = "https://api.lithosai.cloud/v1";
            models = [
              { name = "deepseek-ai/DeepSeek-V4.1-Flash"; }
              { name = "deepseek-ai/DeepSeek-V4.1-Flash-fast"; }
            ];
          }
        ];
      };
    };
    home.sessionVariables.AICHAT_ENV_FILE = aiEnv;
  };
}
