import std/[json, os]
import starintel_doc/validation
let mode = paramStr(1)
for line in stdin.lines:
  let value = parseWireJson(line)
  if mode == "emit": echo stringifyWireJson(value)
  else:
    let result = roundtripWireDocument(value)
    let checked = result.validation
    if mode == "reject": echo $(%*{"accepted": checked.ok, "error": checked.message})
    else:
      if not checked.ok: quit(checked.message, 1)
      echo stringifyWireJson(result.document)
