#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: sh verify-change.sh --change DIR [--base REF] [--head REF]
                           [--command CMD] [--baseline] [--protected PATTERN]...
                           [--root DIR] [--strict] [--quiet]

Verify an Intent v2 change against its declarations and repository checks.
A change record is a proposal.md holding YAML front matter and the intent
body; the proposal digest covers the body only.

Options:
  --change DIR        Change directory containing proposal.md
                      (default: the only change record under .intent/changes/)
  --base REF          Revision the change starts from (default: HEAD)
  --head REF          Revision holding the change (default: the working tree)
  --command CMD       Verification command run from the repository root
  --baseline          Also require the command to pass at --base
  --protected PATTERN Protect matching paths (repeatable; overrides config policy)
  --root DIR          Repository root (default: Git root of the current directory)
  --strict            Fail when schema validation cannot run instead of skipping
  --quiet             Suppress warnings
  --print-digest      Print the body digest of proposal.md and exit
  --help              Show this help
EOF
}

fail() {
  printf 'verify-change: error: %s\n' "$1" >&2
  exit 1
}

say() {
  printf 'verify-change: %s\n' "$1"
}

warn() {
  [ "$quiet" -eq 1 ] || printf 'verify-change: WARN: %s\n' "$1"
}

errors=0

note_fail() {
  printf 'verify-change: FAIL: %s\n' "$1"
  errors=$((errors + 1))
}

# True when PATH matches PATTERN. Patterns arrive as already-quoted shell
# words (never a word list to expand), so `case` supplies the pattern
# semantics; additionally, a `**/` segment may match zero directories, so
# `**/*.md` covers a top-level `README.md` the way authors expect.
path_matches() {
  p=$1
  w=$2
  case "$w" in $p) return 0 ;; esac
  case "$p" in
    '**/'*) path_matches "${p#\*\*/}" "$w" && return 0 ;;
    *'/**/'*)
      head=${p%%'/**/'*}
      tail=${p#*'/**/'}
      path_matches "${head}/${tail}" "$w" && return 0
      ;;
  esac
  return 1
}

# Rejects front-matter lines outside the documented subset (spec §3.2): tabs,
# comments, flow collections, anchors, tags, aliases, and block scalars. The
# empty-list spelling `[]` stays allowed. A hard error, not a warning, so
# unsupported syntax can never silently disable a check.
front_matter_check() {
  bad=$(awk '
    {
      line = $0
      sub(/\r$/, "", line)
    }
    line == "" { next }
    line ~ /\t/ { print NR ": tab character"; exit }
    {
      bare = line
      gsub(/"[^"]*"/, "", bare)
      if (bare ~ /(^|[ \t])#/) { print NR ": comment"; exit }
      if (bare ~ /[{}\[\]&!]/) {
        if (bare ~ /^[[:space:]]*[A-Za-z_]+:[[:space:]]*\[\][[:space:]]*$/) next
        print NR ": flow collection, anchor, or tag"; exit
      }
      if (bare ~ /^[[:space:]]*[A-Za-z_]+:[[:space:]]*[|>*]/) { print NR ": block scalar or alias"; exit }
      if (bare ~ /^[[:space:]]*-[[:space:]]*[|>*]/) { print NR ": block scalar or alias"; exit }
    }
  ' "$1")
  [ -z "$bad" ] || fail "proposal.md front matter uses unsupported syntax (line $bad)"
}

default_protected='tests/**
test/**
spec/**
**/*.test.*
**/*.spec.*
**/*_test.*
**/test_*.py'

change_arg=
base=HEAD
head_ref=
command=
baseline=0
root_arg=
protected=
protected_set=0
print_digest=0
strict=0
quiet=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --change)
      [ "$#" -ge 2 ] || fail "--change requires a directory"
      change_arg=$2
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || fail "--base requires a revision"
      base=$2
      shift 2
      ;;
    --head)
      [ "$#" -ge 2 ] || fail "--head requires a revision"
      head_ref=$2
      shift 2
      ;;
    --command)
      [ "$#" -ge 2 ] || fail "--command requires a command"
      command=$2
      shift 2
      ;;
    --baseline)
      baseline=1
      shift
      ;;
    --protected)
      [ "$#" -ge 2 ] || fail "--protected requires a pattern"
      protected="${protected}${protected:+
}$2"
      protected_set=1
      shift 2
      ;;
    --strict)
      strict=1
      shift
      ;;
    --quiet)
      quiet=1
      shift
      ;;
    --root)
      [ "$#" -ge 2 ] || fail "--root requires a directory"
      root_arg=$2
      shift 2
      ;;
    --print-digest)
      print_digest=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*) fail "unknown option: $1" ;;
    *) fail "unexpected argument: $1" ;;
  esac
done

if [ -n "$root_arg" ]; then
  [ -d "$root_arg" ] || fail "root directory does not exist: $root_arg"
  if git_root=$(git -C "$root_arg" rev-parse --show-toplevel 2>/dev/null); then
    root=$git_root
  else
    root=$(CDPATH= cd "$root_arg" && pwd -P) || fail "cannot resolve root directory: $root_arg"
  fi
else
  root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "current directory is not inside a Git repository; use --root DIR"
fi
root=$(CDPATH= cd "$root" && pwd -P) || fail "cannot resolve repository root"

if [ -n "$change_arg" ]; then
  case $change_arg in
    /*) change_dir=$change_arg ;;
    *) change_dir=$root/$change_arg ;;
  esac
else
  change_dir=
  change_count=0
  for candidate in "$root"/.intent/changes/*/; do
    [ -f "$candidate/proposal.md" ] || continue
    change_dir=${candidate%/}
    change_count=$((change_count + 1))
  done
  [ "$change_count" -eq 1 ] || fail "specify --change DIR: found $change_count change records under .intent/changes"
fi
[ -d "$change_dir" ] || fail "change directory does not exist: ${change_arg:-$change_dir}"
proposal=$change_dir/proposal.md
[ -f "$proposal" ] || fail "missing proposal.md in ${change_arg:-$change_dir}"

config=$root/.intent/config.yaml
tmp=$(mktemp -d "${TMPDIR:-/tmp}/intent-verify.XXXXXX") || fail "cannot create temporary directory"
baseline_dir=
cleanup() {
  if [ -n "$baseline_dir" ] && [ -d "$baseline_dir" ]; then
    git -C "$root" worktree remove --force "$baseline_dir" >/dev/null 2>&1 || rm -rf "$baseline_dir"
    git -C "$root" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

sha256_file() {
  tr -d '\r' < "$1" | sha256_stdin
}

bom_present() {
  [ "$(head -c 3 "$1" | od -An -t x1 | tr -d ' \n')" = efbbbf ]
}

# Prints the line number where the body starts (the front matter ends at the
# first line that is exactly `---` after line 1). Returns non-zero when the
# file does not open with a front-matter block or never closes it.
body_start_line() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
    }
    NR == 1 {
      if (line != "---") exit 5
      next
    }
    line == "---" { print NR + 1; ok = 1; exit 0 }
    END { if (!ok) exit 6 }
  ' "$1"
}

# Prints the front-matter content lines, CR-stripped, without the delimiters.
front_matter() {
  start=$(body_start_line "$1") || return 1
  awk -v last="$((start - 2))" 'NR >= 2 && NR <= last' "$1" | sed 's/\r$//'
}

# Prints the digest of the body bytes: everything after the front matter with
# all CR bytes removed.
body_digest() {
  start=$(body_start_line "$1") || return 1
  tail -n +"$start" "$1" | tr -d '\r' | sha256_stdin
}

# Top-level front-matter scalar: `key: value` at column 1.
fm_scalar() {
  awk -v key="$1" '
    { sub(/\r$/, "") }
    index($0, key ":") == 1 {
      value = $0
      sub("^" key ":[[:space:]]*", "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$2"
}

# Scalar nested under the `proposal:` map (revision, digest).
fm_proposal_value() {
  awk -v key="$1" '
    { sub(/\r$/, "") }
    /^proposal:/ { in_proposal = 1; next }
    in_proposal && /^[^[:space:]]/ { in_proposal = 0 }
    in_proposal && $0 ~ ("^[[:space:]]+" key ":[[:space:]]*") {
      value = $0
      sub("^[[:space:]]+" key ":[[:space:]]*", "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$2"
}

# List items under `links:` then `KIND:`.
fm_links() {
  fm_section_list links "$1" "$2"
}

# List items nested under `SECTION:` then `KEY:` (e.g. scope.paths,
# links.related). Sibling keys reset the list so items never leak across
# them.
fm_section_list() {
  awk -v section="$1" -v key="$2" '
    { sub(/\r$/, "") }
    $0 ~ ("^" section ":[[:space:]]*$") { in_section = 1; in_list = 0; next }
    in_section && /^[^[:space:]]/ { in_section = 0; in_list = 0 }
    in_section && /^[[:space:]]+[A-Za-z_]+:/ {
      if ($0 ~ ("^[[:space:]]+" key ":[[:space:]]*$")) { in_list = 1 } else { in_list = 0 }
      next
    }
    in_section && in_list && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      if (value != "") print value
      next
    }
  ' "$3"
}

# Declared test_changes paths, in order.
test_change_paths() {
  awk '
    { sub(/\r$/, "") }
    /^test_changes:/ { in_list = 1; next }
    in_list && /^[^[:space:]]/ { in_list = 0 }
    in_list && /^[[:space:]]*-[[:space:]]*path:/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      if (value != "") print value
    }
  ' "$1"
}

# Declared test_changes kinds, in order.
test_change_kinds() {
  awk '
    { sub(/\r$/, "") }
    /^test_changes:/ { in_list = 1; next }
    in_list && /^[^[:space:]]/ { in_list = 0 }
    in_list && /^[[:space:]]+kind:/ {
      value = $0
      sub(/^[[:space:]]+kind:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
    }
  ' "$1"
}

# True when the changed path matches a declared test_changes entry, exact or
# glob. Reads the list produced by test_change_paths.
path_declared_as_test_change() {
  wanted=$1
  found=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if path_matches "$entry" "$wanted"; then
      found=1
      break
    fi
  done < "$test_change_list"
  [ "$found" -eq 1 ]
}

config_has_key() {
  awk -v section="$2" -v key="$3" '
    { sub(/\r$/, "") }
    $0 == section ":" { in_section = 1; next }
    /^[a-z_]+:/ { in_section = 0 }
    in_section && $0 ~ ("^[[:space:]]+" key ":") { found = 1 }
    END { print found + 0 }
  ' "$1"
}

config_list() {
  awk -v section="$2" -v key="$3" '
    { sub(/\r$/, "") }
    $0 ~ ("^" section ":[[:space:]]*$") { in_section = 1; in_list = 0; next }
    in_section && /^[a-z_]+:/ { in_section = 0; in_list = 0 }
    in_section && /^[[:space:]]+[A-Za-z_]+:/ {
      if ($0 ~ ("^[[:space:]]+" key ":[[:space:]]*$")) { in_list = 1 } else { in_list = 0 }
      next
    }
    in_section && in_list && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      if (value != "") print value
      next
    }
  ' "$1"
}

config_bool() {
  awk -v section="$2" -v key="$3" '
    { sub(/\r$/, "") }
    $0 == section ":" { in_section = 1; next }
    /^[a-z_]+:/ { in_section = 0 }
    in_section && $0 ~ ("^[[:space:]]+" key ":[[:space:]]*") {
      value = $0
      sub("^[[:space:]]+" key ":[[:space:]]*", "", value)
      print (value == "true") ? 1 : 0
      exit
    }
  ' "$1"
}

config_protected_paths() {
  awk '
    { sub(/\r$/, "") }
    /^policy:/ { in_policy = 1; next }
    /^[a-z_]+:/ { in_policy = 0; in_paths = 0; next }
    in_policy && /^[[:space:]]+protected_paths:/ { in_paths = 1; next }
    in_policy && in_paths && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      if (value != "") print value
      next
    }
  ' "$1"
}

config_verify_command() {
  awk '
    { sub(/\r$/, "") }
    /^policy:/ { in_policy = 1; next }
    /^[a-z_]+:/ { in_policy = 0 }
    in_policy && /^[[:space:]]+verify_command:/ {
      value = $0
      sub(/^[[:space:]]+verify_command:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$1"
}

config_require_baseline() {
  awk '
    { sub(/\r$/, "") }
    /^policy:/ { in_policy = 1; next }
    /^[a-z_]+:/ { in_policy = 0 }
    in_policy && /^[[:space:]]+require_baseline:/ {
      value = $0
      sub(/^[[:space:]]+require_baseline:[[:space:]]*/, "", value)
      print (value == "true") ? 1 : 0
      exit
    }
  ' "$1"
}

config_review_required() {
  awk '
    { sub(/\r$/, "") }
    /^review:/ { in_review = 1; next }
    /^[a-z_]+:/ { in_review = 0 }
    in_review && /^[[:space:]]+required:/ {
      value = $0
      sub(/^[[:space:]]+required:[[:space:]]*/, "", value)
      print (value == "true") ? 1 : 0
      exit
    }
  ' "$1"
}

config_authorized_reviewers() {
  awk '
    { sub(/\r$/, "") }
    /^review:/ { in_review = 1; next }
    /^[a-z_]+:/ { in_review = 0; in_list = 0; next }
    in_review && /^[[:space:]]+authorized_reviewers:/ { in_list = 1; next }
    in_review && in_list && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      if (value != "") print value
      next
    }
  ' "$1"
}

approved_reviews() {
  awk '
    { sub(/\r$/, "") }
    /^reviews:/ { in_reviews = 1; next }
    in_reviews && /^[^[:space:]]/ { in_reviews = 0 }
    in_reviews && /^[[:space:]]*-[[:space:]]*reviewer_id:/ {
      reviewer = $0
      sub(/^[[:space:]]*-[[:space:]]*reviewer_id:[[:space:]]*/, "", reviewer)
      gsub(/^"|"$/, "", reviewer)
      decision = ""
      next
    }
    in_reviews && /^[[:space:]]+decision:/ {
      decision = $0
      sub(/^[[:space:]]+decision:[[:space:]]*/, "", decision)
      gsub(/^"|"$/, "", decision)
      next
    }
    in_reviews && /^[[:space:]]+proposal_digest:/ {
      digest = $0
      sub(/^[[:space:]]+proposal_digest:[[:space:]]*/, "", digest)
      gsub(/^"|"$/, "", digest)
      if (decision == "approved") print reviewer "\t" digest
      next
    }
  ' "$1"
}

schema_validate() {
  schema_dir=$root/.intent/schemas/v2
  [ -f "$schema_dir/change.schema.json" ] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  python3 -c 'import yaml, jsonschema' >/dev/null 2>&1 || return 2
  review_path=
  if [ -f "$change_dir/review.yaml" ]; then review_path=$change_dir/review.yaml; fi
  config_path=
  if [ -f "$config" ]; then config_path=$config; fi
  python3 - "$schema_dir" "$fm" "$review_path" "$config_path" <<'PY'
import json
import sys

import jsonschema
import yaml

schema_dir, change_path, review_path, config_path = sys.argv[1:5]
failed = False


def check(schema_name, target, label):
    global failed
    if not target:
        return
    try:
        with open(schema_dir + "/" + schema_name) as handle:
            schema = json.load(handle)
        with open(target) as handle:
            data = yaml.safe_load(handle)
        jsonschema.validate(data, schema)
    except jsonschema.ValidationError as exc:
        print("%s: %s" % (label, exc.message))
        failed = True
    except yaml.YAMLError as exc:
        print("%s: invalid YAML: %s" % (label, exc))
        failed = True
    except Exception as exc:  # unexpected tooling or schema unavailability
        print("unavailable: %s (%s)" % (label, exc))
        raise SystemExit(2)


check("change.schema.json", change_path, "proposal.md")
check("review.schema.json", review_path, "review.yaml")
check("config.schema.json", config_path, "config.yaml")
raise SystemExit(1 if failed else 0)
PY
}

normalize_status() {
  awk -F'\t' '
    {
      status = $1
      path = $2
      if (status ~ /^[RC]/) path = $3
      if (path != "") print status "\t" path
    }
  '
}

file_diff() {
  if [ -n "$head_ref" ]; then
    git -C "$root" diff -U0 "$base" "$head_ref" -- "$1"
  else
    git -C "$root" diff -U0 "$base" -- "$1"
  fi
}

run_verification() {
  dir=$1
  label=$2
  if (cd "$dir" && sh -c "$command") > "$tmp/command-output" 2>&1; then
    say "$label verification command passed"
  else
    note_fail "$label verification command failed"
    sed 's/^/  /' "$tmp/command-output" >&2
  fi
}

# A proposal without front matter has no digest to print; the whole file is
# treated as the body so authors can bootstrap a record by writing the body
# first and pasting the printed digest into new front matter.
if [ "$print_digest" -eq 1 ]; then
  if start=$(body_start_line "$proposal"); then
    printf 'sha256:%s\n' "$(tail -n +"$start" "$proposal" | tr -d '\r' | sha256_stdin)"
  else
    printf 'sha256:%s\n' "$(tr -d '\r' < "$proposal" | sha256_stdin)"
  fi
  exit 0
fi

git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1 || fail "root is not inside a Git repository: $root"
git -C "$root" rev-parse --verify "$base^{commit}" >/dev/null 2>&1 || fail "base revision not found: $base"
if [ -n "$head_ref" ]; then
  git -C "$root" rev-parse --verify "$head_ref^{commit}" >/dev/null 2>&1 || fail "head revision not found: $head_ref"
fi

if bom_present "$proposal"; then
  note_fail "proposal.md begins with a byte order mark"
fi

fm=$tmp/front-matter
if start=$(body_start_line "$proposal"); then
  front_matter "$proposal" > "$fm"
else
  fail "proposal.md is missing valid front matter: $proposal"
fi
front_matter_check "$fm"

patterns_file=$tmp/protected-patterns
if [ "$protected_set" -eq 1 ]; then
  printf '%s\n' "$protected" > "$patterns_file"
elif [ -f "$config" ] && [ "$(config_has_key "$config" policy protected_paths)" = 1 ]; then
  config_protected_paths "$config" > "$patterns_file"
else
  printf '%s\n' "$default_protected" > "$patterns_file"
fi

if [ -z "$command" ] && [ -f "$config" ]; then
  command=$(config_verify_command "$config")
fi
if [ "$baseline" -eq 0 ] && [ -f "$config" ] && [ "$(config_require_baseline "$config")" = 1 ]; then
  baseline=1
fi
if [ "$baseline" -eq 1 ] && [ -z "$command" ]; then
  fail "--baseline requires --command or policy.verify_command"
fi

recorded=$(fm_proposal_value digest "$fm")
if [ -z "$recorded" ]; then
  note_fail "change record does not provide a proposal digest"
else
  actual=sha256:$(body_digest "$proposal")
  if [ "$recorded" = "$actual" ]; then
    say "proposal digest matches"
  else
    note_fail "proposal digest mismatch: front matter records $recorded but the body is $actual"
  fi
fi

status_value=$(fm_scalar status "$fm")
review_required_value=$(fm_scalar review_required "$fm")
protocol_value=$(fm_scalar protocol_version "$fm")
for field in protocol_version id title status created_at request review_required; do
  grep -q "^$field:" "$fm" || note_fail "record is missing required field: $field"
done
grep -q '^proposal:' "$fm" || note_fail "record is missing required field: proposal"
[ -n "$(fm_proposal_value revision "$fm")" ] || note_fail "proposal is missing required field: revision"
[ -n "$(fm_proposal_value digest "$fm")" ] || note_fail "proposal is missing required field: digest"
[ "$protocol_value" = "2.0" ] || note_fail "unsupported protocol_version: ${protocol_value:-<missing>}"
case " draft in_review changes_requested rejected approved implementing conformance_review complete withdrawn " in
  *" $status_value "*) ;;
  *) note_fail "unknown change status: ${status_value:-<missing>}" ;;
esac
case $review_required_value in
  true|false) ;;
  *) note_fail "review_required must be true or false: ${review_required_value:-<missing>}" ;;
esac
revision_value=$(fm_proposal_value revision "$fm")
case "$revision_value" in
  ''|*[!0-9]*) note_fail "proposal revision must be a positive integer: ${revision_value:-<missing>}" ;;
  *) [ "$revision_value" -ge 1 ] || note_fail "proposal revision must be a positive integer: $revision_value" ;;
esac
id_value=$(fm_scalar id "$fm")
case "$id_value" in
  ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) note_fail "change id must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$: ${id_value:-<missing>}" ;;
  *) [ "${#id_value}" -le 64 ] || note_fail "change id must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$: $id_value" ;;
esac
[ -n "$(fm_scalar title "$fm")" ] || note_fail "title must not be empty"
[ -n "$(fm_scalar request "$fm")" ] || note_fail "request must not be empty"
created_value=$(fm_scalar created_at "$fm")
case "$created_value" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ;;
  *) note_fail "created_at must be an RFC 3339 timestamp: ${created_value:-<missing>}" ;;
esac
if [ -n "$recorded" ]; then
  case "$recorded" in
    sha256:*) digest_hex=${recorded#sha256:} ;;
    *) digest_hex= ;;
  esac
  case "$digest_hex" in
    *[!0-9a-f]*|'') note_fail "proposal digest must be a sha256: digest: $recorded" ;;
    *) [ "${#digest_hex}" -eq 64 ] || note_fail "proposal digest must be a sha256: digest: $recorded" ;;
  esac
fi
test_change_kinds "$fm" > "$tmp/test-change-kinds"
while IFS= read -r kind_value; do
  case " added modified deleted skipped " in
    *" $kind_value "*) ;;
    *) note_fail "test_changes kind is not one of added, modified, deleted, skipped: ${kind_value:-<missing>}" ;;
  esac
done < "$tmp/test-change-kinds"
if [ "$status_value" = complete ] && [ ! -f "$change_dir/conformance.md" ]; then
  note_fail "status complete requires conformance.md"
fi

# Declared links must resolve to records or decision files that exist.
fm_links related "$fm" > "$tmp/link-changes"
fm_links supersedes "$fm" >> "$tmp/link-changes"
while IFS= read -r linked; do
  [ -n "$linked" ] || continue
  if [ ! -f "$root/.intent/changes/$linked/proposal.md" ]; then
    note_fail "unknown change link: $linked"
  fi
done < "$tmp/link-changes"
fm_links decisions "$fm" > "$tmp/link-decisions"
while IFS= read -r linked; do
  [ -n "$linked" ] || continue
  if [ ! -f "$root/.intent/decisions/$linked.md" ]; then
    note_fail "unknown decision link: $linked"
  fi
done < "$tmp/link-decisions"

approval_required=0
if [ -f "$config" ] && [ "$(config_review_required "$config")" = 1 ]; then
  approval_required=1
fi
if [ "$review_required_value" = true ]; then
  approval_required=1
fi
case $status_value in
  approved|implementing|conformance_review|complete)
    if [ "$approval_required" -eq 1 ] && [ -n "$recorded" ]; then
      if [ -f "$change_dir/review.yaml" ]; then
        approved_reviews "$change_dir/review.yaml" > "$tmp/approved-reviews"
      else
        : > "$tmp/approved-reviews"
      fi
      matching=$(awk -F'\t' -v digest="$recorded" '$2 == digest { print $1 }' "$tmp/approved-reviews")
      if [ -z "$matching" ]; then
        note_fail "approval evidence for the current proposal digest is missing"
      else
        authorized=
        if [ -f "$config" ]; then
          authorized=$(config_authorized_reviewers "$config")
        fi
        if [ -n "$authorized" ]; then
          authorized_ok=0
          for reviewer in $matching; do
            for allowed in $authorized; do
              if [ "$reviewer" = "$allowed" ]; then authorized_ok=1; fi
            done
          done
          [ "$authorized_ok" -eq 1 ] || note_fail "approval reviewer is not in authorized_reviewers: $matching"
        fi
      fi
    fi
    ;;
esac

schema_output=$tmp/schema-output
if schema_validate > "$schema_output" 2>&1; then
  say "records match the pinned schemas"
else
  schema_rc=$?
  if [ "$schema_rc" -eq 2 ]; then
    if [ "$strict" -eq 1 ]; then
      note_fail "schema validation skipped (python3 with PyYAML and jsonschema, or pinned schemas, unavailable); --strict requires it"
    else
      warn "schema validation skipped (python3 with PyYAML and jsonschema, or pinned schemas, unavailable)"
    fi
  else
    while IFS= read -r line; do
      note_fail "schema: $line"
    done < "$schema_output"
  fi
fi

raw=$tmp/raw-status
if [ -n "$head_ref" ]; then
  git -C "$root" diff --name-status "$base" "$head_ref" -- | normalize_status > "$raw"
else
  {
    git -C "$root" diff --name-status "$base" --
    git -C "$root" ls-files --others --exclude-standard | awk '{ print "A\t" $0 }'
  } | normalize_status > "$raw"
fi

changed_all=$tmp/changed-all
changed_declared=$tmp/changed-declared
: > "$changed_all"
: > "$changed_declared"
while IFS="$(printf '\t')" read -r status path; do
  [ -n "$path" ] || continue
  printf '%s\n' "$path" >> "$changed_all"
  case $path in .intent/*) continue ;; esac
  case $status in
    A*) ;;
    *) printf '%s\n' "$path" >> "$changed_declared" ;;
  esac
done < "$raw"

scope_paths_file=$tmp/scope-paths
fm_section_list scope paths "$fm" > "$scope_paths_file"
warn_unused=1
if [ -f "$config" ] && [ "$(config_has_key "$config" policy warn_unused_paths)" = 1 ]; then
  [ "$(config_bool "$config" policy warn_unused_paths)" = 1 ] || warn_unused=0
fi
if [ -s "$scope_paths_file" ]; then
  outside_scope=0
  # Patterns are read line by line and matched through path_matches, so they
  # are never expanded (no word lists, no pathname expansion) and may contain
  # spaces.
  while IFS= read -r path; do
    case "$path" in .intent/*) continue ;; esac
    match=0
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      if path_matches "$pattern" "$path"; then
        match=1
        break
      fi
    done < "$scope_paths_file"
    if [ "$match" -eq 0 ]; then
      note_fail "path outside declared scope: $path"
      outside_scope=1
    fi
  done < "$changed_all"
  if [ "$warn_unused" -eq 1 ]; then
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      matched=0
      while IFS= read -r path; do
        case "$path" in .intent/*) continue ;; esac
        if path_matches "$pattern" "$path"; then
          matched=1
          break
        fi
      done < "$changed_all"
      [ "$matched" -eq 1 ] || warn "declared scope path matched no changed file: $pattern"
    done < "$scope_paths_file"
  fi
  [ "$outside_scope" -eq 1 ] || say "changed paths are within declared scope"
fi

test_change_list=$tmp/test-changes
test_change_paths "$fm" > "$test_change_list"
if [ -s "$patterns_file" ]; then
  while IFS= read -r path; do
    case "$path" in .intent/*) continue ;; esac
    match=0
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      if path_matches "$pattern" "$path"; then
        match=1
        break
      fi
    done < "$patterns_file"
    [ "$match" -eq 1 ] || continue
    if ! path_declared_as_test_change "$path"; then
      note_fail "protected path changed but missing from test_changes: $path"
    fi
  done < "$changed_declared"
fi

weaken_re='^-[[:space:]]*((def|func|fn)[[:space:]]+[Tt]est|it\(|test\(|describe\(|#\[test\]|@Test)'
skip_re='^\+.*(\.(skip|only)\(|xit\(|@Ignore|@Disabled|#\[ignore\]|pytest\.mark\.skip|t\.Skip\()'
while IFS= read -r path; do
  case $path in .intent/*) continue ;; esac
  file_diff "$path" > "$tmp/file-diff" || true
  if grep -Eq -- "$weaken_re" "$tmp/file-diff" || grep -Eq -- "$skip_re" "$tmp/file-diff"; then
    if ! path_declared_as_test_change "$path"; then
      note_fail "test definition removed or skipped but not declared in test_changes: $path"
    fi
  fi
done < "$changed_declared"

if [ "$baseline" -eq 1 ]; then
  baseline_dir=$tmp/baseline
  git -C "$root" worktree add --detach "$baseline_dir" "$base" >/dev/null 2>&1 || fail "cannot create a baseline worktree at $base"
  run_verification "$baseline_dir" "baseline ($base)"
fi
if [ -n "$command" ]; then
  run_verification "$root" "change"
fi

if [ "$errors" -gt 0 ]; then
  printf 'verify-change: %s check(s) failed\n' "$errors" >&2
  exit 1
fi
say "change verified: $change_arg"
