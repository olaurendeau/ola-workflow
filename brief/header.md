# ola-workflow — the rules for this project

Profile: {{profile}}
Mode:    {{mode}}
{{#schema_mismatch}}

## This profile does not match the schema

Read what follows with that in mind, and tell the human. A key spelled wrong is a
key that is not there, so a rule you are about to read may be a default of mine
standing in for one this project meant to set:

{{problems_indented}}
{{/schema_mismatch}}
{{#missing_any}}

## Not in the profile — these are my defaults, not this project's rules

{{missing_lines}}

Treat them as a question to ask rather than a decision to enforce. Rejecting a
change for breaking a budget nobody set is worse than not having a budget.
{{/missing_any}}
Base branch: {{base}}{{#base_from_origin}} (not in the profile — read from origin/HEAD){{/base_from_origin}}{{#base_guessed}} (not in the profile, and origin/HEAD says nothing — a guess){{/base_guessed}} — nobody pushes to it, every change arrives by
pull request.
