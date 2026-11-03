## Keeping context small

Everything you read or print stays in your context for the rest of the task.

- No busy-waiting on CI: no `until … sleep`, no `watch`, no `--watch`. Read the state of a
  check once. If it is still running, say so and carry on: whoever needs it green, the merge
  check, will read it again.
- Read a file by line range: Read with an interval, or find the lines with `grep -n` first.
  Never a whole file through `cat`, nor through `git show <sha>:<file>` without a range.
- Silence or bound noisy commands: `git fetch -q`, `git worktree list` filtered, and any
  output that may run past a screen goes through `tail`, `grep` or `head`. From a test run,
  keep the summary and the failures.
- Short reports: the Status, the deliverables, one line per finding. Write the detail where
  the memory lives (see Memory below) and point the report at it.
