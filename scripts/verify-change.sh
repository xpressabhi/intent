#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: sh verify-change.sh --change DIR [--base REF] [--head REF]
                           [--command CMD] [--baseline] [--protected PATTERN]...
                           [--root DIR]

Verify an Intent change against its declarations and repository checks.

Options:
  --change DIR        Change directory containing change.yaml and proposal.md
                      (default: the only change record under .intent/changes/)
  --base REF          Revision the change starts from (default: HEAD)
  --head REF          Revision holding the change (default: the working tree)
  --command CMD       Verification command run from the repository root
  --baseline          Also require the command to pass at --base
  --protected PATTERN Protect matching paths (repeatable; overrides config policy)
  --root DIR          Repository root (default: Git root of the current directory)
  --print-digest      Print the normalized proposal.md digest and exit
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
    --print-digest)
      print_digest=1
      shift
      ;;
    --protected)
      [ "$#" -ge 2 ] || fail "--protected requires a pattern"
      protected="${protected}${protected:+ }$2"
      protected_set=1
      shift 2
      ;;
    --root)
      [ "$#" -ge 2 ] || fail "--root requires a directory"
      root_arg=$2
      shift 2
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
    [ -f "$candidate/change.yaml" ] || continue
    change_dir=${candidate%/}
    change_count=$((change_count + 1))
  done
  [ "$change_count" -eq 1 ] || fail "specify --change DIR: found $change_count change records under .intent/changes"
fi
[ -d "$change_dir" ] || fail "change directory does not exist: ${change_arg:-$change_dir}"
change_yaml=$change_dir/change.yaml
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

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    tr -d '\r' < "$1" | sha256sum | awk '{print $1}'
  else
    tr -d '\r' < "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

bom_present() {
  [ "$(head -c 3 "$1" | od -An -t x1 | tr -d ' \n')" = efbbbf ]
}

change_digest() {
  awk '
    { sub(/\r$/, "") }
    /^proposal:/ { in_proposal = 1; next }
    in_proposal && /^[^[:space:]]/ { in_proposal = 0 }
    in_proposal && /^[[:space:]]+digest:/ {
      value = $0
      sub(/^[[:space:]]+digest:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$1"
}

test_change_paths() {
  awk '
    { sub(/\r$/, "") }
    /^test_changes:/ { in_list = 1; next }
    in_list && /^[^[:space:]#]/ { in_list = 0 }
    in_list && /^[[:space:]]*-[[:space:]]*path:/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
    }
  ' "$1"
}

scope_paths() {
  awk '
    { sub(/\r$/, "") }
    /^[a-z_]+:/ { in_scope = ($0 == "scope:") ? 1 : 0; in_paths = 0; next }
    in_scope && /^[[:space:]]+paths:/ { in_paths = 1; next }
    in_scope && in_paths && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      if (value != "") print value
      next
    }
  ' "$1"
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

top_scalar() {
  awk -v key="$2" '
    { sub(/\r$/, "") }
    index($0, key ":") == 1 {
      value = $0
      sub("^" key ":[[:space:]]*", "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
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
  schema_dir=$root/.intent/schemas/v1
  [ -f "$schema_dir/change.schema.json" ] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  python3 -c 'import yaml, jsonschema' >/dev/null 2>&1 || return 2
  review_path=
  [ -f "$change_dir/review.yaml" ] && review_path=$change_dir/review.yaml
  config_path=
  [ -f "$config" ] && config_path=$config
  python3 - "$schema_dir" "$change_yaml" "$review_path" "$config_path" <<'PY'
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
    except Exception as exc:  # tooling or schema unavailable for this draft
        print("unavailable: %s (%s)" % (label, exc))
        raise SystemExit(2)


check("change.schema.json", change_path, "change.yaml")
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

if [ "$print_digest" -eq 1 ]; then
  printf 'sha256:%s\n' "$(sha256_file "$proposal")"
  exit 0
fi

[ -f "$change_yaml" ] || fail "missing change.yaml in ${change_arg:-$change_dir}"
git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1 || fail "root is not inside a Git repository: $root"
git -C "$root" rev-parse --verify "$base^{commit}" >/dev/null 2>&1 || fail "base revision not found: $base"
if [ -n "$head_ref" ]; then
  git -C "$root" rev-parse --verify "$head_ref^{commit}" >/dev/null 2>&1 || fail "head revision not found: $head_ref"
fi

patterns=$default_protected
if [ "$protected_set" -eq 1 ]; then
  patterns=$protected
elif [ -f "$config" ] && [ "$(config_has_key "$config" policy protected_paths)" = 1 ]; then
  patterns=$(config_protected_paths "$config")
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

errors=0
note_fail() {
  printf 'verify-change: FAIL: %s\n' "$1"
  errors=$((errors + 1))
}

recorded=$(change_digest "$change_yaml")
if [ -z "$recorded" ]; then
  note_fail "change.yaml does not record a proposal digest"
else
  actual=sha256:$(sha256_file "$proposal")
  if bom_present "$proposal"; then
    note_fail "proposal.md contains a byte order mark"
  fi
  if [ "$recorded" = "$actual" ]; then
    say "proposal digest matches change.yaml"
  else
    note_fail "proposal digest mismatch: change.yaml records $recorded but proposal.md is $actual"
  fi
fi

status_value=$(top_scalar "$change_yaml" status)
review_required_value=$(top_scalar "$change_yaml" review_required)
protocol_value=$(top_scalar "$change_yaml" protocol_version)
for field in protocol_version id title status created_at request proposal scope decisions review_required; do
  grep -q "^$field:" "$change_yaml" || note_fail "change.yaml is missing required field: $field"
done
[ "$protocol_value" = "1.0" ] || note_fail "unsupported protocol_version: ${protocol_value:-<missing>}"
case " draft in_review changes_requested rejected approved implementing conformance_review complete " in
  *" $status_value "*) ;;
  *) note_fail "unknown change status: ${status_value:-<missing>}" ;;
esac
case $review_required_value in
  true|false) ;;
  *) note_fail "review_required must be true or false: ${review_required_value:-<missing>}" ;;
esac
if [ "$status_value" = complete ] && [ ! -f "$change_dir/conformance.md" ]; then
  note_fail "status complete requires conformance.md"
fi

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
    say "schema validation skipped (python3 with PyYAML and jsonschema, or pinned schemas, unavailable)"
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

scope_patterns=$(scope_paths "$change_yaml")
if [ -n "$scope_patterns" ]; then
  outside_scope=0
  while IFS= read -r path; do
    case $path in .intent/*) continue ;; esac
    match=0
    for pattern in $scope_patterns; do
      case $path in $pattern) match=1; break ;; esac
    done
    if [ "$match" -eq 0 ]; then
      note_fail "path outside declared scope: $path"
      outside_scope=1
    fi
  done < "$changed_all"
  [ "$outside_scope" -eq 1 ] || say "changed paths are within declared scope"
fi

test_change_list=$tmp/test-changes
test_change_paths "$change_yaml" > "$test_change_list"
if [ -n "$patterns" ]; then
  while IFS= read -r path; do
    case $path in .intent/*) continue ;; esac
    match=0
    for pattern in $patterns; do
      case $path in $pattern) match=1; break ;; esac
    done
    [ "$match" -eq 1 ] || continue
    if ! grep -Fq -- "$path" "$proposal"; then
      note_fail "protected path changed but not declared in the proposal: $path"
    fi
    if ! grep -Fqx -- "$path" "$test_change_list"; then
      note_fail "protected path changed but missing from change.yaml test_changes: $path"
    fi
  done < "$changed_declared"
fi

weaken_re='^-[[:space:]]*((def|func|fn)[[:space:]]+[Tt]est|it\(|test\(|describe\(|#\[test\]|@Test)'
skip_re='^\+.*(\.(skip|only)\(|xit\(|@Ignore|@Disabled|#\[ignore\]|pytest\.mark\.skip|t\.Skip\()'
while IFS= read -r path; do
  case $path in .intent/*) continue ;; esac
  file_diff "$path" > "$tmp/file-diff" || true
  if grep -Eq -- "$weaken_re" "$tmp/file-diff" || grep -Eq -- "$skip_re" "$tmp/file-diff"; then
    if ! grep -Fq -- "$path" "$proposal"; then
      note_fail "test definition removed or skipped but not declared in the proposal: $path"
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
