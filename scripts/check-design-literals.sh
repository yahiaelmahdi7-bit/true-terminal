#!/bin/bash
# Design-literal check (true-design-pass plan, "Fixes after review").
# Patterns: `white.opacity(` and `.font(.system(size:` anywhere in Sources/ outside the allow-list.
# Allow-list: Sources/True/Terminal/**, Theme.swift, Motion.swift.
# Hue exceptions (SitePill green, PeerViews red, MarkupRender) are now Theme.Hue / Theme.MarkupInk tokens.
# Mode: report-only (always exits 0). Pass --enforce to exit 1 when literals remain (not wired into the gate yet).
set -u
cd "$(dirname "$0")/.." || exit 2
ALLOW='^Sources/True/(Terminal/|Chrome/Theme\.swift|Chrome/Motion\.swift)'

count() { # pattern -> prints "file:line:text" for non-allow-listed hits
  grep -rnE --include='*.swift' -e "$1" Sources | grep -Ev "$ALLOW" || true
}

op=$(count 'white\.opacity\(')
fs=$(count '\.font\(\.system\(size:')
n_op=$([ -n "$op" ] && printf '%s\n' "$op" | wc -l | tr -d ' ' || echo 0)
n_fs=$([ -n "$fs" ] && printf '%s\n' "$fs" | wc -l | tr -d ' ' || echo 0)

echo "design literals outside the allow-list (report-only)"
echo "  white.opacity(        : $n_op"
echo "  .font(.system(size:   : $n_fs"
[ -n "${VERBOSE:-}" ] && { printf '%s\n' "$op" "$fs" | sed '/^$/d'; }

total=$((n_op + n_fs))
echo "total literals: $total"
if [ "${1:-}" = "--enforce" ] && [ "$total" -gt 0 ]; then exit 1; fi
exit 0
