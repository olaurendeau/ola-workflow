## What each agent runs on

| agent | `model` | `effort` | what it buys |
|---|---|---|---|
| coordinator | *(none)* | *(none)* | the session agent: the human picks its model |
| product-designer | `sonnet` | *(none)* | long writing, bounded by a glossary and a brief |
| design-reviewer | `sonnet` | *(none)* | a checklist held against one page |
| architect | `opus` | *(none)* | a plausible split whose third task needs the fifth is paid for in full |
| developer | `sonnet` | `high` | the largest volume here, on a task already specified file by file |
| pr-reviewer | `opus` | `high` | the defect the author could not see — twice at a time, since 0.5.0 runs a reviewer per slot |
| security-reviewer | `opus` | `high` | a path from an attacker to a sink, and the refutation of every path that is not one: a false positive costs a developer a cycle |
| probe | `haiku` | `low` | one `echo`, so that a hook records a payload |

The rule is **Opus where a wrong judgement costs a whole cycle, Sonnet where the volume is.**
The design-reviewer and the pr-reviewer are not the same kind of reviewer, which is why they
are not on the same model: the design-reviewer holds a page against criteria somebody already wrote down, and
the pr-reviewer has to find what nobody wrote down.

The `high` pins are a ceiling rather than a cut. They hold the three heaviest roles at
`high` however high the session is set, and the session is what they used to follow.

The coordinator pins nothing, deliberately. It is the role a project names as its session
agent, and a frontmatter `effort` is measured to have no effect at all there — see
[Agent identity](agent-identity.md). So a key on the coordinator would be either ignored, or,
for the model, a choice taken behind the human who set the session's.

Two things follow from pinning the others:

- **`CLAUDE_CODE_SUBAGENT_MODEL` no longer reaches them.** A model resolves in this order:
  the `model` parameter of the dispatch, then the frontmatter, then that variable, then the
  session's model. Past the second step the variable is never read, so the one remaining way
  to run a role on something else for a single dispatch is that parameter — which the
  coordinator holds.
- **`effort` and `model` are not claims of the same strength.** A `PreToolUse` payload
  carries `effort`, so what a plugin subagent reflects at is *measured* — see
  [Agent identity](agent-identity.md). No payload field carries the model, so that column is
  read from the documentation and seen in the session, not measured.

`tests/agents.test.sh` keeps this table as a map declared beside the test: a role that stops
pinning its model, pins another one, or is added without being named in the map fails by
name.

What is deliberately **not** written here is a saving. A saving is a number that has to be
*true*, not merely unchallenged, so it belongs to something that recomputes it rather than to
a sentence every later review would have to check again.
