## Commands
Everything CI runs:  {{check_full}}{{#check_full_absent}}(none declared — ask the human what proves this project works){{/check_full_absent}}
The affected subset: {{check_affected}}{{#check_affected_absent}}{{check_full}}{{#check_full_absent}}(none declared){{/check_full_absent}} — the same command: this project declares no subset.{{/check_affected_absent}}
{{#check_cleanup}}
After a check:        {{check_cleanup}}
{{/check_cleanup}}

Any {slot} in those commands is replaced by the slot you were given. Read a value
with the slot already substituted: ola-profile get check.affected --slot <n>
