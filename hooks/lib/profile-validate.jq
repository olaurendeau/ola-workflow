# Validates a profile against schema/profile.schema.json, passed in as $schema.
#
# This interprets the schema rather than restating it, so the schema stays the single
# source of truth: a key added there is checked here with no code change. It covers the
# keywords the profile schema uses — type, enum, required, properties,
# additionalProperties: false, items, minItems, minimum — and ignores anything else.
#
# Prints one line per problem; no output means the profile is valid.

def tname:
  if type == "number" and (. == floor) then "integer" else type end;

def type_ok($want):
  tname as $actual
  | ($want | if type == "array" then . else [.] end)
  | any(. == $actual or (. == "number" and $actual == "integer"));

def errors($schema; $path):
  . as $v
  | ( if ($schema | has("type")) and (type_ok($schema.type) | not)
      then ["\($path): expected \($schema.type | tostring), got \($v | tname)"]
      else [] end )
  + ( if ($schema | has("enum")) and (($schema.enum | any(. == $v)) | not)
      then ["\($path): \($v | tojson) is not one of \($schema.enum | join(", "))"]
      else [] end )
  + ( if ($schema | has("minimum")) and ($v | type) == "number" and $v < $schema.minimum
      then ["\($path): \($v) is below the minimum of \($schema.minimum)"]
      else [] end )
  + ( if ($schema | has("minItems")) and ($v | type) == "array" and ($v | length) < $schema.minItems
      then ["\($path): \($v | length) items, at least \($schema.minItems) required"]
      else [] end )
  + ( if ($v | type) == "object" then
        ( (($schema.required // []) - ($v | keys))
          | map("\($path)/\(.): required key is missing") )
      + ( if $schema.additionalProperties == false
          then ( (($v | keys) - (($schema.properties // {}) | keys))
                 | map("\($path)/\(.): unknown key") )
          else [] end )
      + ( [ ($v | keys[]) as $k
            | if ($schema.properties // {}) | has($k)
              then ($v[$k] | errors($schema.properties[$k]; "\($path)/\($k)"))
              else [] end ]
          | add // [] )
      else [] end )
  + ( if ($v | type) == "array" and ($schema | has("items")) then
        ( [ ($v | to_entries[]) as $e
            | ($e.value | errors($schema.items; "\($path)[\($e.key)]")) ]
          | add // [] )
      else [] end );

errors($schema[0]; "profile")[]
