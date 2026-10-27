# Applies a claude-profile settings overlay ($overlay[0]) to the input: objects
# merge key by key, any other value replaces, and null deletes the key, because
# hooks merge across settings scopes and omission is the only way to drop one.
def overlay($o):
  if ($o | type) == "object" then
    reduce ($o | to_entries[]) as $e ((if type == "object" then . else {} end);
      if $e.value == null then del(.[$e.key]) else .[$e.key] |= overlay($e.value) end)
  else $o end;

# HARNESS_WORK and WIKI_VAULT keep the machine's values, so ~/.harness.env is
# the only switch between work and personal.
. as $base
| overlay($overlay[0])
| reduce ("HARNESS_WORK", "WIKI_VAULT") as $k (.;
    if ($base.env // {}) | has($k) then .env[$k] = $base.env[$k] else del(.env[$k]) end)
