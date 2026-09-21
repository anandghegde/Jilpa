#!/bin/bash
# Enforces what SwiftPM cannot: the forbidden imports in the layering table of
# docs/ARCHITECTURE.md, and a few contract rules that are cheap to check as text.
#
# SwiftPM only checks declared edges. AppKit is importable from any macOS target, and an
# undeclared sibling module can resolve by accident because all modules share a build directory.
#
# usage: Scripts/lint-imports.sh        exits 1 on any violation

set -euo pipefail
cd "$(dirname "$0")/.."

# target | Jilpa modules it may import ("*" for any) | system modules it must not import
LAYERS='
JilpaCore      | -                                 | AppKit Cocoa SwiftUI ApplicationServices GRDB
JilpaConfig    | JilpaCore                         | AppKit Cocoa SwiftUI
JilpaStore     | JilpaCore                         | AppKit Cocoa SwiftUI
JilpaCompat    | JilpaCore                         | AppKit Cocoa SwiftUI
JilpaIPC       | -                                 | AppKit Cocoa SwiftUI
JilpaAX        | -                                 | AppKit Cocoa SwiftUI
JilpaDialog    | JilpaCore JilpaAX JilpaCompat     |
JilpaNavigator | JilpaCore JilpaAX JilpaCompat JilpaDialog |
JilpaSensors   | JilpaCore JilpaAX                 |
JilpaUI        | JilpaCore                         | ApplicationServices GRDB
JilpaApp       | *                                 |
'

failures=0

report() {
  echo "error: $1" >&2
  failures=$((failures + 1))
}

# Prints "file:line:module" for every import statement under a directory.
imports_in() {
  grep -rEn --include='*.swift' \
    '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]' \
    "$1" 2>/dev/null |
    sed -E 's/^([^:]+:[0-9]+):.*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*).*/\1:\4/' ||
    true
}

trim() {
  echo "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

seen_targets=""
while IFS='|' read -r target allowed forbidden; do
  target=$(trim "$target")
  [ -z "$target" ] && continue
  allowed=$(trim "$allowed")
  forbidden=$(trim "$forbidden")
  seen_targets="$seen_targets $target"
  dir="Sources/$target"
  [ -d "$dir" ] || { report "$dir is in the layering table but does not exist"; continue; }

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    module="${entry##*:}"
    location="${entry%:*}"
    case "$module" in
      "$target") ;;
      Jilpa*)
        if [ "$allowed" != "*" ]; then
          case " $allowed " in
            *" $module "*) ;;
            *) report "$location: $target must not import $module" ;;
          esac
        fi
        ;;
      *)
        case " $forbidden " in
          *" $module "*) report "$location: $target must not import $module" ;;
        esac
        ;;
    esac
  done < <(imports_in "$dir")
done <<< "$LAYERS"

# A new target must be added to the table before it can hold code.
for dir in Sources/*/; do
  name=$(basename "$dir")
  case " $seen_targets " in
    *" $name "*) ;;
    *) report "Sources/$name has no row in the layering table of Scripts/lint-imports.sh" ;;
  esac
done

# Contract rules. Comment lines are skipped so the rules can be written down next to the code.
code_matches() {
  grep -rEn --include='*.swift' "$1" Sources App 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' || true
}

# Navigation safety: keys go to the host pid, never to the global HID or session stream.
while IFS= read -r hit; do
  [ -n "$hit" ] && report "$hit: post events with postToPid only, never to a global event tap location"
done < <(code_matches '\.post\(tap:|CGEventPost\(')

# Input and focus: no keyboard tap. The one event tap is the dialog-scoped mouse tap in the
# Finder bridge.
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  case "$hit" in
    Sources/JilpaSensors/*) ;;
    *) report "$hit: event taps are allowed only in JilpaSensors (the dialog-scoped mouse tap)" ;;
  esac
done < <(code_matches 'tapCreate\(|CGEventTapCreate\(')

while IFS= read -r hit; do
  [ -n "$hit" ] && report "$hit: no keyboard events in an event tap mask; hotkeys use RegisterEventHotKey"
done < <(code_matches 'CGEventType\.(keyDown|keyUp|flagsChanged)|kCGEventKey(Down|Up)|kCGEventFlagsChanged')

# These switches change host behavior and performance.
while IFS= read -r hit; do
  [ -n "$hit" ] && report "$hit: never set AXManualAccessibility or AXEnhancedUserInterface on a host"
done < <(code_matches 'AXManualAccessibility|AXEnhancedUserInterface')

if [ "$failures" -gt 0 ]; then
  echo "$failures layering or contract violation(s)" >&2
  exit 1
fi
echo "lint-imports: ok"
