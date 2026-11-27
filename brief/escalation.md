## Escalation — what belongs to the human
- Scope and product: what a user sees, departing from what was asked.
- Dependencies: adding a runtime dependency, any major version upgrade.
- Process and security: CI, rulesets, quality thresholds, hooks, agent definitions.
{{#approval}}
- Loosening a check or a quality threshold.
- Ruling that a security finding is a false positive.
- Widening a token, or what a token may do.
- Changing the settings or the rulesets of the repository.
{{/approval}}
{{#approval_release_current}}
- Release: whether to release, and the version. The release itself is the human's act.
{{/approval_release_current}}
{{#approval_release_human}}
- Release: the human decides whether to release, and the version. Once they have asked, the coordinator does the whole chain: the release pull request, the annotated tag, the GitHub release.
{{/approval_release_human}}
{{#escalation_extra}}
{{escalation_extra}}
{{/escalation_extra}}
{{#approval}}

Who approves each step:
- Design: {{#approval_design_human}}the human{{/approval_design_human}}{{#approval_design_agent}}the design-reviewer, with no stop for the human{{/approval_design_agent}}{{#approval_design_omitted}} (not in the profile — my default){{/approval_design_omitted}}
- Architecture: {{#approval_architecture_human}}the human{{/approval_architecture_human}}{{#approval_architecture_agent}}no stop for the human{{/approval_architecture_agent}}{{#approval_architecture_omitted}} (not in the profile — my default){{/approval_architecture_omitted}}
- Merge: {{#discreet}}nothing is merged here{{/discreet}}{{#integrated}}{{#approval_merge_human}}the human merges every pull request{{/approval_merge_human}}{{#approval_merge_agent}}the coordinator merges a pull request whose gate holds{{/approval_merge_agent}}{{#approval_merge_when}}the human merges a pull request that touches a path or matches a pattern of approval.merge.human_when, the coordinator any other whose gate holds{{/approval_merge_when}}{{#approval_merge_omitted}}the human merges a pull request that touches merge.sensitive_paths or matches merge.sensitive_patterns, the coordinator any other whose gate holds (not in the profile — my default){{/approval_merge_omitted}}{{/integrated}}
- Release: {{#discreet}}nothing is published on the forge here{{/discreet}}{{#integrated}}{{#approval_release_human}}the human decides; once they have asked, the coordinator does the whole chain{{/approval_release_human}}{{#approval_release_agent}}the coordinator decides whether to release, and the version{{/approval_release_agent}}{{#approval_release_current}}the human decides, and acts{{/approval_release_current}}{{#approval_release_omitted}} (not in the profile — my default){{/approval_release_omitted}}{{/integrated}}
{{/approval}}

Anything else, decide yourself and favour the option closest to existing code.
Record a decision where the work lives: Decision: … — Reason: …
