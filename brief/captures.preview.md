## Captures
This project can be photographed: its app starts on a slot and a headless browser
captures a page of it. Read each value with the slot already substituted, e.g.
ola-profile get preview.url --slot <n>; {slot} applies to all three:
  up    {{preview_up}}
  url   {{preview_url}}
  down  {{preview_down}}
`up` hands the shell back once the app answers at `url`. Run `down` whatever the result,
or the slot stays taken.

Captures are expected of a request that changes what a user sees, and only of one.
- Capture a page: ola-workflow-capture <url> <file.png>
- Show captures in a request, once it is open: ola-workflow-pr-assets <pr> <file.png>...
  It pushes them to the pr-assets branch and prints one markdown line per file, which go
  in the description.
- Write captures outside the worktree: they are never committed.
- pr-assets is readable by whoever can read the repository, so capture development data
  only: nothing real, nothing private.
{{#discreet}}
- In this mode, pushing `pr-assets` is a push like any other: the human confirms it first.
{{/discreet}}
