## Agent identity

<!-- spike:begin -->
Three things the documentation does not say, and that the hooks, the default session agent
and the per-role models all depend on. Measured with `make spike` on **Claude Code 2.1.305**,
2026-10-20:

| scenario | `agent_type` | `agent_id` | `effort` |
|---|---|---|---|
| main session, no agent | *absent* | *absent* | `high` |
| subagent, `subagent_type: ola-workflow:probe` | `ola-workflow:probe` | present | `low` |
| subagent, `subagent_type: probe` | — the call fails, see below | — | — |
| `--agent ola-workflow:probe` | `ola-workflow:probe` | *absent* | `medium` |
| `--agent probe` | `ola-workflow:probe` | *absent* | `medium` |
| `"agent"` passed with `--settings` | `ola-workflow:probe` | *absent* | `medium` |
| `"agent"` in a project's `.claude/settings.json` | `ola-workflow:probe` | *absent* | `medium` |
| subagent, `CLAUDE_CODE_EFFORT_LEVEL=high` | `ola-workflow:probe` | present | `high` |

The `effort` column is read from the payload of the same probe, which pins `effort: low`.

What this means:

- **`agent_type` is always the namespaced name** `<plugin>:<agent>`, both for a subagent and
  for a session agent. A plugin agent has no bare alias. The name is built from the plugin
  name, the path under `agents/` and the frontmatter `name`, so `agents/<dir>/<name>.md`
  would be `ola-workflow:<dir>:<name>`. (A template, not a name: `tests/agents.test.sh`
  checks that every `ola-workflow:…` written in a prompt or here resolves to something
  shipped, so an illustration has to be visibly an illustration.) The elevation hook accepts
  only an `ola-workflow:` name and keeps the part after the last `:`.
- **`agent_id`, not `agent_type`, tells a subagent from a session agent**: it is present only
  inside a subagent, and absent on the main thread even under `--agent`.
- **A missing agent has no `agent_type` key at all** — not `""`, not `main`.
- **`settings.json` accepts the namespaced name**, including in a project's committed
  `.claude/settings.json`, which is how a project pins its default agent:
  `"agent": "ola-workflow:coordinator"`. `--agent` additionally accepts the bare name
  (resolved by `:`-suffix), and a missing `--agent` is fatal while a missing settings `agent`
  does not stop the session.
- **The Agent tool is different: `subagent_type` is an exact match.** A bare name does not
  resolve to a plugin agent:

  ```
  Agent type 'probe' not found. Available agents: claude, Explore, general-purpose,
  ola-workflow:probe, Plan, statusline-setup
  ```

  So the coordinator has to dispatch `ola-workflow:developer`, never `developer`. The same
  holds for a skill's `agent:` key.
- **A frontmatter `effort` reaches a subagent — and only a subagent.** `probe` pins
  `effort: low`: dispatched with the Agent tool it runs at `low`, and the very same file run
  as a session agent runs at `medium`, which is the model's own default and not what the file
  asks for. The key is read exactly where the work happens, and the coordinator could not pin
  its own effort even if that were wanted.
- **`CLAUDE_CODE_EFFORT_LEVEL` outranks the frontmatter.** The same dispatch with it set to
  `high` runs at `high`, not at the `low` the file asks for — so it is the session's escape
  hatch from every effort this plugin pins. The model has no hatch of that shape: there the
  frontmatter outranks `CLAUDE_CODE_SUBAGENT_MODEL`, not the other way round.
- **No payload field carries the model.** The fields below are all a hook is offered, so what
  a role runs *on* cannot be measured this way — only what it runs *at*. That is the whole
  difference in strength between the two columns of
  [What each agent runs on](models.md).

The fields a `PreToolUse` payload offers a hook, as measured:
`agent_id`, `agent_type`, `cwd`, `effort`, `hook_event_name`, `permission_mode`, `prompt_id`,
`session_id`, `tool_input`, `tool_name`, `tool_use_id`, `transcript_path`. `effort` is an
object — `{"level": "high"}` — not a string.

Re-run `make spike` after a Claude Code upgrade: none of this is contractual. The eight
scenarios live in [`scripts/spike/agent-identity.sh`](../scripts/spike/agent-identity.sh); it
loads the plugin with `--plugin-dir`, so nothing is installed and nothing is written inside
the repository.
<!-- spike:end -->

### Publishing an artifact from a plugin agent

The product-designer publishes visual work as a claude.ai artifact and keeps it at one URL.
Measured on **Claude Code 2.1.299**, 2026-10-14, with
[`scripts/spike/agent-artifact.sh`](../scripts/spike/agent-artifact.sh):

| scenario | `Artifact` available | publish, then publish with `url` |
|---|---|---|
| `claude -p`, main session | no | — |
| `claude -p`, plugin agent declaring `Artifact` | no | — |
| interactive, `general-purpose` subagent | yes, loaded directly | not measured |
| interactive, plugin agent declaring `Write, Artifact` | yes | same URL, version 1 then 2 |

So a plugin agent gets the tool by naming it in `tools:`, and a second publish with `url`
updates the page in place. **Headless runs have no `Artifact` at all**, the main session
included, which is why this spike is replayed by hand: `make spike-artifact` prints the
session to start and the prompt to paste. It publishes one private page in the account of
whoever runs it.
