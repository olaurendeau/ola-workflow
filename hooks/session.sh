#!/usr/bin/env bash
# SessionStart: every Bash command of a session in a project with a profile runs with the
# base GitHub token, which can neither merge nor write a commit status.
#
# Claude Code sources CLAUDE_ENV_FILE before each Bash command, in the main session and in
# every subagent, so one line here covers every agent of the session. A project with no
# profile is left alone, and so is one whose profile says "github_tokens": "off".
#
# What this hook prints on stdout goes into the session's context, which is how an agent
# learns that the tokens are missing before its first gh call fails.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=hooks/lib/profile.sh
. "$SELF_DIR/lib/profile.sh"
# shellcheck source=hooks/lib/github-tokens.sh
. "$SELF_DIR/lib/github-tokens.sh"

input=$(cat)
cwd=""
command -v jq >/dev/null 2>&1 && cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=$(pwd)

ola_profile_path "$cwd" >/dev/null 2>&1 || exit 0
[ "$(ola_profile_get github_tokens "$cwd" "" keychain 2>/dev/null)" = off ] && exit 0

if [ -z "${CLAUDE_ENV_FILE:-}" ]; then
  echo "ola-workflow: this Claude Code gives the hook no CLAUDE_ENV_FILE, so the agents of this session use the human's own GitHub login, with every right it has. Nothing stops a merge or a review status but the prompts."
  exit 0
fi
ola_token_env_line >>"$CLAUDE_ENV_FILE"

if ! ola_token_read base >/dev/null; then
  echo "ola-workflow: there is no base GitHub token in the keychain, so every gh call of this session will fail with a 401. Tell the human to run: ola-workflow-tokens setup"
fi
exit 0
