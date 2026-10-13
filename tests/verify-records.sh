#!/bin/sh

set -eu

repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
checker=$repo_root/scripts/verify-records.sh
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/intent-records-tests.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM
passed=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

new_repo() {
  dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf 'base\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm base
  base_sha=$(git -C "$dir" rev-parse HEAD)
}

commit_all() {
  dir=$1
  msg1=$2
  msg2=${3-}
  git -C "$dir" add -A
  if [ -n "$msg2" ]; then
    git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "$msg1" -m "$msg2"
  else
    git -C "$dir" -c user.email=t@t -c user.name=t commit -qm "$msg1"
  fi
}

make_record() {
  dir=$1
  id=${2:-CHG-0001}
  mkdir -p "$dir/.intent/changes/$id"
  printf 'record body\n' > "$dir/.intent/changes/$id/proposal.md"
}

run_checker() { sh "$checker" "$@" > "$temp_root/out" 2>&1; }

expect_pass() {
  desc=$1
  shift
  if run_checker "$@"; then
    pass "$desc"
  else
    fail "$desc (expected pass; output: $(cat "$temp_root/out"))"
  fi
}

expect_pass_with_output() {
  desc=$1
  needle=$2
  shift 2
  if run_checker "$@"; then :; else fail "$desc (expected pass; output: $(cat "$temp_root/out"))"; fi
  grep -Fq -- "$needle" "$temp_root/out" || fail "$desc (missing output '$needle'; output: $(cat "$temp_root/out"))"
  pass "$desc"
}

expect_fail() {
  desc=$1
  needle=$2
  shift 2
  if run_checker "$@"; then
    fail "$desc (expected failure, checker passed)"
  fi
  grep -Fq -- "$needle" "$temp_root/out" || fail "$desc (missing message '$needle'; output: $(cat "$temp_root/out"))"
  pass "$desc"
}

# A code-only change with no record fails.
repo=$temp_root/no-record
new_repo "$repo"
mkdir -p "$repo/src"
printf 'console.log(1)\n' > "$repo/src/app.js"
expect_fail 'code change without a record fails' 'no Intent record' --base "$base_sha" --root "$repo"

# The same change with one record passes and prints the directory.
repo=$temp_root/with-record
new_repo "$repo"
mkdir -p "$repo/src"
printf 'console.log(1)\n' > "$repo/src/app.js"
make_record "$repo"
expect_pass_with_output 'code change with one record passes and names it' 'verify-records: record .intent/changes/CHG-0001' --base "$base_sha" --root "$repo"

# A docs-only change passes without a record.
repo=$temp_root/docs-only
new_repo "$repo"
mkdir -p "$repo/docs"
printf 'notes\n' > "$repo/docs/notes.md"
expect_pass_with_output 'docs-only change needs no record' 'docs-only change; no record required' --base "$base_sha" --root "$repo"

# An Intent-Skip trailer in a commit message passes with a notice.
repo=$temp_root/skip-trailer
new_repo "$repo"
mkdir -p "$repo/src"
printf 'hotfix\n' > "$repo/src/hotfix.js"
commit_all "$repo" 'quick fix' 'Intent-Skip: hotfix in production'
expect_pass_with_output 'Intent-Skip trailer passes with a notice' 'verify-records: Intent-Skip: hotfix in production' --base "$base_sha" --root "$repo"

# The same string mid-line is not a trailer.
repo=$temp_root/skip-midline
new_repo "$repo"
mkdir -p "$repo/src"
printf 'hotfix\n' > "$repo/src/hotfix.js"
commit_all "$repo" 'notes' 'see Intent-Skip: not a trailer'
expect_fail 'Intent-Skip mid-line does not count' 'no Intent record' --base "$base_sha" --root "$repo"

# Two record directories in one range fail.
repo=$temp_root/two-records
new_repo "$repo"
mkdir -p "$repo/src"
printf 'change\n' > "$repo/src/app.js"
make_record "$repo" CHG-0001
make_record "$repo" CHG-0002
expect_fail 'two records fail as one record per change' 'one record per change' --base "$base_sha" --root "$repo"

# Configured exempt globs are respected (the config itself is committed first,
# since a custom list replaces the defaults).
repo=$temp_root/exempt-config
new_repo "$repo"
mkdir -p "$repo/.intent"
cat > "$repo/.intent/config.yaml" <<'EOF'
protocol_version: "2.0"
review:
  required: false
  authorized_reviewers: []
policy:
  record_exempt_paths:
    - "assets/**"
EOF
commit_all "$repo" 'configure the exempt globs'
base_sha=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$repo/assets"
printf 'logo\n' > "$repo/assets/logo.png"
expect_pass_with_output 'configured exempt globs need no record' 'no record required' --base "$base_sha" --root "$repo"

# Record maintenance alone is exempt.
repo=$temp_root/record-only
new_repo "$repo"
make_record "$repo" CHG-0001
printf 'evidence\n' > "$repo/.intent/changes/CHG-0001/conformance.md"
expect_pass_with_output 'record-only maintenance is exempt' 'no record required' --base "$base_sha" --root "$repo"

printf 'All %s coverage-gate scenarios passed.\n' "$passed"
