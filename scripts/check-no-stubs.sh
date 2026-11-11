#!/usr/bin/env bash
# Stub scan over the lines ADDED between two commits: TODO, FIXME, coming soon, placeholder, not implemented
# (case-insensitive). Usage: check-no-stubs.sh <base> <head>
# Exit 0 clean, 1 stubs found, 2 usage or git error.
set -u
[ $# -eq 2 ] || { echo "usage: $0 <base> <head>" >&2; exit 2; }
base=$1; head=$2

# Files that talk about the stub words on purpose (the scanner, its tests, the plan and its paperwork).
# An explicit list: the words themselves are never loosened.
ALLOW_FILES=(
  scripts/check-no-stubs.sh
  scripts/test-check-no-stubs.sh
  scripts/check-group-ledger.py
  scripts/test_check_group_ledger.py
  docs/designs/group-rebuild.md
  docs/designs/group-rebuild-ledger.md
  docs/designs/group-rebuild-brief-template.md
)
# Results reports may talk about the words: markdown only, under either path (true and true-cloud).
ALLOW_PREFIXES=(
  docs/designs/group-rebuild-results/
  docs/group-rebuild-results/
)
# Real API spellings that contain a stub word. Removed from a line before it is scanned.
ALLOW_API_REGEX='\.placeholder([^[:alnum:]_]|$)'
# Two-word phrases match with a space, hyphen, underscore or nothing between them (comingSoon, not_implemented()).
WORDS='TODO|FIXME|coming[ _-]?soon|placeholder|not[ _-]?implemented|unimplemented'

# --no-renames: a renamed file is scanned as a new file. quotePath=false: non-ASCII names stay readable.
diff=$(git -c core.quotePath=false diff --no-renames --no-ext-diff -U0 --no-color "$base" "$head") \
  || { echo "FAIL: git diff failed for $base..$head" >&2; exit 2; }

found=0
file=""
state=header   # header: reading a file's diff header; hunk: every line starting with + is an added line
while IFS= read -r line; do
  if [ "$state" = hunk ]; then
    case "$line" in
      "diff --git "*) state=header; file="" ;;
      "+"*) ;;
      *) continue ;;
    esac
  fi
  if [ "$state" = header ]; then
    case "$line" in
      "+++ "*)
        file=${line#"+++ "}; file=${file%$'\t'}
        case "$file" in \"*\") file=${file#\"}; file=${file%\"} ;; esac
        file=${file#b/} ;;
      "@@ "*) state=hunk ;;
    esac
    continue
  fi
  skip=0
  for f in "${ALLOW_FILES[@]}"; do [ "$file" = "$f" ] && skip=1; done
  for p in "${ALLOW_PREFIXES[@]}"; do
    case "$file" in "$p"*.md) skip=1 ;; esac
  done
  [ $skip -eq 1 ] && continue
  text=${line#+}
  scrub=$(printf '%s' "$text" | sed -E "s/$ALLOW_API_REGEX/\\1/g")
  if printf '%s' "$scrub" | grep -qiE "$WORDS"; then
    echo "STUB: $file: $text"
    found=1
  fi
done <<EOF
$diff
EOF

if [ $found -ne 0 ]; then
  echo "FAIL: stub words in added lines" >&2
  exit 1
fi
echo "ok: no stub words in added lines ($base..$head)"
