#!/usr/bin/env bash
# Fixture tests for check-no-stubs.sh. Builds a throwaway git repo per case.
set -u
here=$(cd "$(dirname "$0")" && pwd)
scan="${SCAN:-$here/check-no-stubs.sh}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0

# case <name> <want-exit> <path> <content>
run_case() {
  local name=$1 want=$2 path=$3 content=$4
  local r="$tmp/$name"
  mkdir -p "$r" && cd "$r" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  echo base > base.txt && git add . && git commit -qm base
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  git add . && git commit -qm change
  "$scan" HEAD~1 HEAD >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then pass=$((pass+1)); echo "PASS $name (exit $got)"
  else fail=$((fail+1)); echo "FAIL $name: want $want got $got"; fi
}

run_case clean            0 a.swift  'let x = 1'
run_case todo             1 a.swift  '// TODO fix'
run_case fixme_lower      1 a.swift  '// fixme later'
run_case coming_soon      1 a.swift  'Text("Coming Soon")'
run_case placeholder_word 1 a.swift  'let placeholder = "Name"'
run_case not_implemented  1 a.py     'raise NotImplementedError  # Not Implemented'
run_case swiftui_api      0 a.swift  'Text("x").redacted(reason: .placeholder)'
run_case api_plus_word    1 a.swift  '.redacted(reason: .placeholder) // placeholder'
run_case own_script       0 scripts/check-no-stubs.sh 'WORDS="TODO|FIXME"'
run_case own_ledger_check 0 scripts/check-group-ledger.py '# no TODO here'
run_case plan_doc         0 docs/designs/group-rebuild.md 'stub scan: TODO, placeholder'
run_case results_doc      0 docs/designs/group-rebuild-results/F0.md 'mentions TODO'
run_case similar_path     1 scripts/other.sh '# TODO'
run_case second_clean_line 0 a.swift 'let ok = true'

# results folder: markdown only, both paths
run_case results_swift    1 docs/designs/group-rebuild-results/x.swift '// TODO'
run_case results_md_cloud 0 docs/group-rebuild-results/F1.md 'mentions TODO'
run_case results_swift_cl 1 docs/group-rebuild-results/x.py '# TODO'
# added line whose text starts with "++ " must not be read as a header
run_case plusplus_line    1 a.swift  '++ TODO hide'
# a name with spaces and a non-ASCII name are scanned under their own names
run_case space_name       1 'dir/a b.swift' '// TODO'

# code spellings of the two-word phrases, and unimplemented
run_case notimpl_error    1 a.py     'raise NotImplementedError'
run_case notimpl_fn       1 a.py     'not_implemented()'
run_case notimpl_hyphen   1 a.py     '# not-implemented yet'
run_case coming_hyphen    1 a.js     'label = "coming-soon"'
run_case coming_camel     1 a.js     'const comingSoon = true'
run_case coming_under     1 a.js     'COMING_SOON'
run_case unimplemented    1 a.swift  'fatalError("unimplemented")'
run_case api_still_ok     0 a.swift  'x.redacted(reason: .placeholder)'

# non-ASCII name sorting after an allow-listed file: its TODO must not inherit the allow-listed name
r="$tmp/unicode"; mkdir -p "$r/scripts"; cd "$r" || exit 1
git init -q . && git config user.email t@t && git config user.name t
echo base > base.txt && git add . && git commit -qm base
echo 'x' > scripts/check-no-stubs.sh; printf '// TODO\n' > "é.swift"
git add . && git commit -qm change
"$scan" HEAD~1 HEAD >/dev/null 2>&1; got=$?
if [ "$got" -eq 1 ]; then pass=$((pass+1)); echo "PASS unicode_name"; else fail=$((fail+1)); echo "FAIL unicode_name: want 1 got $got"; fi

# rename with an appended stub is scanned
r="$tmp/rename"; mkdir -p "$r"; cd "$r" || exit 1
git init -q . && git config user.email t@t && git config user.name t
seq 1 30 > old.swift && git add . && git commit -qm base
git mv old.swift new.swift && echo '// TODO later' >> new.swift
git add . && git commit -qm change
"$scan" HEAD~1 HEAD >/dev/null 2>&1; got=$?
if [ "$got" -eq 1 ]; then pass=$((pass+1)); echo "PASS rename"; else fail=$((fail+1)); echo "FAIL rename: want 1 got $got"; fi

# git failure must fail safe (exit non-zero, never 0)
"$scan" no-such-ref HEAD >/dev/null 2>&1; got=$?
if [ "$got" -ne 0 ]; then pass=$((pass+1)); echo "PASS git_failure_fails (exit $got)"; else fail=$((fail+1)); echo "FAIL git_failure_fails: exited 0"; fi

# a stub already in base and merely present (not added) must not trip
r="$tmp/preexisting"; mkdir -p "$r"; cd "$r" || exit 1
git init -q . && git config user.email t@t && git config user.name t
echo '// TODO old' > old.swift && git add . && git commit -qm base
echo 'let y = 2' > new.swift && git add . && git commit -qm change
"$scan" HEAD~1 HEAD >/dev/null 2>&1; got=$?
if [ "$got" -eq 0 ]; then pass=$((pass+1)); echo "PASS preexisting_not_added"; else fail=$((fail+1)); echo "FAIL preexisting_not_added: got $got"; fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
