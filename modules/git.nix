# Git identity, system-wide (/etc/gitconfig) — every user incl. root and
# `nix shell nixpkgs#git` sessions on all NixOS hosts. GitHub links commits
# to the wylited account ONLY by this noreply email. Git precedence is
# system < global: a stray ~/.gitconfig [user] would shadow this, so don't
# set one — this file is the single source of truth (2026-10-25 drift:
# agent-passed `git -c user.email=wyli@wyli.tech` needed a history rewrite).
{ ... }:

{
  programs.git = {
    enable = true; # also puts git in environment.systemPackages
    config = {
      user = {
        name = "wylited";
        email = "44154103+wylited@users.noreply.github.com";
      };
      init.defaultBranch = "main";
    };
  };
}
