## Slots
Variable: {{slots_var}} · developers: {{slots_developers}}{{#slots_developers_absent}}(none declared){{/slots_developers_absent}} · reviewers: {{slots_reviewer}}{{#slots_reviewer_absent}}(none declared){{/slots_reviewer_absent}}
A slot is what keeps parallel work from colliding on ports, databases and containers.
Never run a command with another agent's slot. One agent per slot: never more
developers at once than developer slots, nor more reviewers than reviewer slots.
