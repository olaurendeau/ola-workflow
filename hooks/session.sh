#!/usr/bin/env bash
# SessionStart: every Bash command of a session in a project with a profile runs with the
# base token of the project's forge: on GitHub, one that can neither merge nor write a commit
# status; on GitLab, for the project's host only, in integrated mode the agents' bot, in
# discreet mode the human's granular token for this project only.
#
# Claude Code sources CLAUDE_ENV_FILE before each Bash command, in the main session and in
# every subagent, so one line here covers every agent of the session. A project with no
# profile is left alone, and so is one whose profile says "github_tokens": "off" (the key
# keeps its name for both forges).
#
# What this hook prints on stdout goes into the session's context, which is how an agent
# learns that the tokens are missing before its first gh or glab call fails.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=hooks/lib/profile.sh
. "$SELF_DIR/lib/profile.sh"
# shellcheck source=hooks/lib/github-tokens.sh
. "$SELF_DIR/lib/github-tokens.sh"
# shellcheck source=hooks/lib/gitlab-tokens.sh
. "$SELF_DIR/lib/gitlab-tokens.sh"

input=$(cat)
cwd=""
command -v jq >/dev/null 2>&1 && cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=$(pwd)

ola_profile_path "$cwd" >/dev/null 2>&1 || exit 0
[ "$(ola_profile_get github_tokens "$cwd" "" keychain 2>/dev/null)" = off ] && exit 0

forge=$(ola_profile_get forge "$cwd" "" github 2>/dev/null)

if [ -z "${CLAUDE_ENV_FILE:-}" ]; then
  if [ "$forge" = gitlab ]; then
    echo "ola-workflow: this Claude Code gives the hook no CLAUDE_ENV_FILE, so the agents of this session use the human's own glab login, with every right it has. Nothing stops a merge or a review status but the prompts."
  else
    echo "ola-workflow: this Claude Code gives the hook no CLAUDE_ENV_FILE, so the agents of this session use the human's own GitHub login, with every right it has. Nothing stops a merge or a review status but the prompts."
  fi
  exit 0
fi
# The GH_TOKEN line is the same in every project, whatever the forge.
ola_token_env_line >>"$CLAUDE_ENV_FILE"

if [ "$forge" = gitlab ]; then
  id=$(ola_gitlab_id "$cwd") || id=""
  # Discreet: the agents act as the human, through a granular token limited to the project.
  # Only the project's own account is read: one kept higher up is not limited to it, and a
  # missing one must never let glab fall back to the human's own login.
  scope=""
  [ "$(ola_profile_mode "$cwd" 2>/dev/null)" = integrated ] || scope=project
  ola_gitlab_env_line "$id" $scope >>"$CLAUDE_ENV_FILE"
  if [ -z "$id" ]; then
    echo "ola-workflow: this project has no remote the hook can read a GitLab host from, so every glab call of this session will fail with a 401. Tell the human to add the remote, then run: ola-workflow-tokens setup"
  elif [ -n "$scope" ]; then
    ola_token_read base "$(ola_gitlab_project_account "$id")" >/dev/null ||
      echo "ola-workflow: there is no GitLab token in the keychain for $id. In discreet mode the agents act as you only through a granular token limited to this project, so every glab call of this session will fail with a 401. Tell the human to run: ola-workflow-tokens setup base"
  elif ! ola_gitlab_token_read base "$id" >/dev/null; then
    echo "ola-workflow: there is no base GitLab token in the keychain for ${id%%/*}, so every glab call of this session will fail with a 401. Tell the human to run: ola-workflow-tokens setup"
  fi
  exit 0
fi

if ! ola_token_read base >/dev/null; then
  echo "ola-workflow: there is no base GitHub token in the keychain, so every gh call of this session will fail with a 401. Tell the human to run: ola-workflow-tokens setup"
fi
exit 0
