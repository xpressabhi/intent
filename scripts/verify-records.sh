#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: sh verify-records.sh --base REF [--head REF] [--root DIR]

Check that a change range carries an Intent change record when repository
policy requires one. Paths matching the repository's exempt globs
(policy.record_exempt_paths; documentation and the Intent bundle by default)
need no record. On success with exactly one record, prints:

  verify-records: record .intent/changes/CHG-XXXX

Options:
  --base REF   Revision the range starts from (required)
  --head REF   Revision holding the change (default: the working tree)
  --root DIR   Repository root (default: Git root of the current directory)
  --help       Show this help
EOF
}

fail() {
  printf 'verify-records: error: %s\n' "$1" >&2
  exit 1
}

say() {
  printf 'verify-records: %s\n' "$1"
}

default_exempt='docs/**
**/*.md
.intent/**'

base=
base_set=0
head_ref=
root_arg=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || fail "--base requires a revision"
      base=$2
      base_set=1
      shift 2
      ;;
    --head)
      [ "$#" -ge 2 ] || fail "--head requires a revision"
      head_ref=$2
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
[ "$base_set" -eq 1 ] || fail "--base is required"

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

git -C "$root" rev-parse --verify "$base^{commit}" >/dev/null 2>&1 || fail "base revision not found: $base"
if [ -n "$head_ref" ]; then
  git -C "$root" rev-parse --verify "$head_ref^{commit}" >/dev/null 2>&1 || fail "head revision not found: $head_ref"
fi

config=$root/.intent/config.yaml
tmp=$(mktemp -d "${TMPDIR:-/tmp}/intent-records.XXXXXX") || fail "cannot create temporary directory"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

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

# True when PATH matches PATTERN; a `**/` segment may match zero directories,
# so `**/*.md` covers a top-level README.md.
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

record_exists() {
  id=$1
  if [ -n "$head_ref" ]; then
    git -C "$root" cat-file -e "$head_ref:.intent/changes/$id/proposal.md" >/dev/null 2>&1
  else
    [ -f "$root/.intent/changes/$id/proposal.md" ]
  fi
}

exempt_file=$tmp/exempt-paths
if [ -f "$config" ] && [ "$(config_has_key "$config" policy record_exempt_paths)" = 1 ]; then
  config_list "$config" policy record_exempt_paths > "$exempt_file"
else
  printf '%s\n' "$default_exempt" > "$exempt_file"
fi

raw=$tmp/raw
if [ -n "$head_ref" ]; then
  git -C "$root" diff --name-status "$base" "$head_ref" -- > "$raw"
else
  {
    git -C "$root" diff --name-status "$base" --
    git -C "$root" ls-files --others --exclude-standard | awk '{ print "A\t" $0 }'
  } > "$raw"
fi

changed=$tmp/changed
awk -F'\t' '
  {
    status = $1
    path = $2
    if (status ~ /^[RC]/) path = $3
    if (path != "") print path
  }
' "$raw" > "$changed"

non_exempt=$tmp/non-exempt
: > "$non_exempt"
all_exempt=1
while IFS= read -r path; do
  [ -n "$path" ] || continue
  match=0
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if path_matches "$pattern" "$path"; then
      match=1
      break
    fi
  done < "$exempt_file"
  if [ "$match" -eq 1 ]; then continue; fi
  all_exempt=0
  printf '%s\n' "$path" >> "$non_exempt"
done < "$changed"

if [ "$all_exempt" -eq 1 ]; then
  say "docs-only change; no record required"
  exit 0
fi

ids=$tmp/ids
: > "$ids"
while IFS= read -r path; do
  case "$path" in
    .intent/changes/*/*)
      rest=${path#.intent/changes/}
      id=${rest%%/*}
      case "$id" in TEMPLATE) continue ;; esac
      if record_exists "$id"; then
        grep -Fqx -- "$id" "$ids" || printf '%s\n' "$id" >> "$ids"
      fi
      ;;
  esac
done < "$changed"

count=$(grep -c . "$ids" || true)

if [ "$count" -eq 0 ]; then
  if [ -n "$head_ref" ]; then
    range="$base..$head_ref"
  else
    range="$base..HEAD"
  fi
  trailer=$(git -C "$root" log --format=%B "$range" 2>/dev/null | grep -E '^Intent-Skip: ' | head -n 1 || true)
  if [ -n "$trailer" ]; then
    reason=${trailer#Intent-Skip: }
    say "Intent-Skip: $reason"
    exit 0
  fi
  printf 'verify-records: FAIL: no Intent record for this change\n' >&2
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '  changed: %s\n' "$path" >&2
  done < "$non_exempt"
  exit 1
fi

if [ "$count" -gt 1 ]; then
  list=
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    list="${list}${list:+ }.intent/changes/$id"
  done < "$ids"
  printf 'verify-records: FAIL: one record per change: %s\n' "$list" >&2
  exit 1
fi

id=$(sed -n '1p' "$ids")
say "record .intent/changes/$id"
