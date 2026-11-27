# Validates a profile against schema/profile.schema.json, passed in as $schema.
#
# This interprets the schema rather than restating it, so the schema stays the single
# source of truth: a key added there is checked here with no code change. It reads these
# keywords and ignores anything else:
#   type, enum, minimum, minItems, required, properties, additionalProperties: false, items;
#   allOf (the problems of every sub-schema, added up);
#   anyOf, oneOf, not, if/then (a sub-schema is valid when it yields no problem, and its
#     inner problems are not printed; then applies when if is valid; there is no else);
#   errorMessage (an annotation: when the schema that carries it has a problem of its own
#     - type, enum, minimum, minItems, required, anyOf, oneOf, not - those lines become the
#     message, {value} standing for the received value as JSON; problems of nested
#     properties and items keep their own line and path).
#
# Under if and not, write only keywords listed above (enum, required, properties, type...),
# never const or pattern: a keyword it does not read is true of everything, so a condition
# built on it always holds, then applies to every profile and a not refuses them all.
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
  # A sub-schema is valid when it yields no problem.
  | def valid($s): ($v | errors($s; $path) | length) == 0;
  # The problems at the level of the schema itself, which errorMessage may replace.
  def own:
    ( if ($schema | has("type")) and (type_ok($schema.type) | not)
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
    + ( if ($v | type) == "object"
        then ( (($schema.required // []) - ($v | keys))
               | map("\($path)/\(.): required key is missing") )
        else [] end )
    + ( if ($schema | has("anyOf")) and (($schema.anyOf | any(valid(.))) | not)
        then ["\($path): matches none of the allowed forms"]
        else [] end )
    + ( if $schema | has("oneOf") then
          ( [ $schema.oneOf[] | select(valid(.)) ] | length ) as $n
          | if $n == 0 then ["\($path): matches none of the allowed forms"]
            elif $n > 1 then ["\($path): matches more than one of the allowed forms"]
            else [] end
        else [] end )
    + ( if ($schema | has("not")) and valid($schema.not)
        then ["\($path): matches a form it must not"]
        else [] end );
  ( own
    | if length > 0 and ($schema | has("errorMessage"))
      then ["\($path): \($schema.errorMessage | split("{value}") | join($v | tojson))"]
      else . end )
  + ( if ($v | type) == "object" then
        ( if $schema.additionalProperties == false
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
      else [] end )
  + ( [ ($schema.allOf // [])[] | . as $s | ($v | errors($s; $path)) ] | add // [] )
  + ( if ($schema | has("if")) and ($schema | has("then")) and valid($schema.if)
      then ($v | errors($schema.then; $path))
      else [] end );

errors($schema[0]; "profile")[]
