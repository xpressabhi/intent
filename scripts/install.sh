#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: sh /path/to/intent/scripts/install.sh [--target DIR] [--reviewer ID]... [--dry-run] [--upgrade]

Install the version-pinned Intent v1 guidance bundle into a Git repository.

Options:
  --target DIR    Repository or directory inside the target Git repository
  --reviewer ID   Add an explicit reviewer alongside CODEOWNERS owners (repeatable)
  --dry-run       Validate and report planned changes without writing
  --upgrade       Replace managed files from the pinned bundle; config.yaml and PROJECT.md stay unchanged
  --help          Show this help
EOF
}

fail() {
  printf 'intent install: error: %s\n' "$1" >&2
  exit 1
}

say() {
  printf 'intent install: %s\n' "$1"
}

reviewer_listed() {
  for existing in $reviewers; do
    [ "$existing" != "$1" ] || return 0
  done
  return 1
}

target_arg=
target_set=0
dry_run=0
upgrade=0
reviewers=
reviewer_count=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || fail "--target requires a directory"
      [ "$target_set" -eq 0 ] || fail "--target may only be specified once"
      target_arg=$2
      target_set=1
      shift 2
      ;;
    --reviewer)
      [ "$#" -ge 2 ] || fail "--reviewer requires an ID"
      reviewer=$2
      case "$reviewer" in
        ''|[!A-Za-z0-9@]*|*[!A-Za-z0-9._:@/+%-]*) fail "invalid reviewer ID: $reviewer" ;;
      esac
      [ "${#reviewer}" -le 128 ] || fail "reviewer ID is longer than 128 characters"
      if reviewer_listed "$reviewer"; then fail "duplicate reviewer ID: $reviewer"; fi
      reviewers="${reviewers}${reviewers:+ }${reviewer}"
      reviewer_count=$((reviewer_count + 1))
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --upgrade)
      upgrade=1
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

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P) || fail "cannot locate installer directory"
intent_root=$(CDPATH= cd "$script_dir/.." && pwd -P) || fail "cannot locate Intent repository"

bundle_source() {
  rel=$1
  rest=${rel#.intent/}
  if [ -f "$intent_root/install/templates/.intent/$rest" ]; then
    printf '%s\n' "$intent_root/install/templates/.intent/$rest"
  elif [ -f "$intent_root/$rest" ]; then
    printf '%s\n' "$intent_root/$rest"
  else
    return 1
  fi
}

if [ "$target_set" -eq 1 ]; then
  [ -d "$target_arg" ] || fail "target directory does not exist: $target_arg"
  target_root=$(git -C "$target_arg" rev-parse --show-toplevel 2>/dev/null) || fail "target is not inside a Git repository: $target_arg"
else
  target_root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "current directory is not inside a Git repository; use --target DIR"
fi
target_root=$(CDPATH= cd "$target_root" && pwd -P) || fail "cannot resolve target Git root"

codeowners_path=
for candidate in "$target_root/.github/CODEOWNERS" "$target_root/CODEOWNERS" "$target_root/docs/CODEOWNERS"; do
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    [ ! -L "$candidate" ] || fail "CODEOWNERS is a symlink: $candidate"
    [ -f "$candidate" ] || fail "CODEOWNERS is not a regular file: $candidate"
    codeowners_path=$candidate
    break
  fi
done

config_was_present=0
[ ! -e "$target_root/.intent/config.yaml" ] || config_was_present=1

stage=$(mktemp -d "${TMPDIR:-/tmp}/intent-install.XXXXXX") || fail "cannot create temporary staging directory"
trap 'rm -rf "$stage"' EXIT HUP INT TERM

if [ -n "$codeowners_path" ]; then
  for codeowner in $(awk '
    {
      sub(/\r$/, "")
      sub(/[[:space:]]+#.*/, "")
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      for (i = 2; i <= NF; i++) {
        if (($i ~ /^@[[:alnum:]][^[:space:]#]*$/ || $i ~ /^[[:alnum:]][[:alnum:]_.+-]*@[[:alnum:].-]+$/) && !seen[$i]++) print $i
      }
    }
  ' "$codeowners_path"); do
    if ! reviewer_listed "$codeowner"; then
      reviewers="${reviewers}${reviewers:+ }${codeowner}"
      reviewer_count=$((reviewer_count + 1))
    fi
  done
fi

relpaths='.intent/config.yaml
.intent/README.md
.intent/PROJECT.md
.intent/AGENT_GUIDE.md
.intent/decisions/README.md
.intent/changes/TEMPLATE/change.yaml.tmpl
.intent/changes/TEMPLATE/proposal.md
.intent/changes/TEMPLATE/review.yaml.tmpl
.intent/changes/TEMPLATE/conformance.md
.intent/protocol/v1.md
.intent/schemas/v1/config.schema.json
.intent/schemas/v1/change.schema.json
.intent/schemas/v1/review.schema.json
.intent/scripts/verify-change.sh'

printf '%s\n' "$relpaths" > "$stage/manifest"

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ "$rel" = ".intent/config.yaml" ]; then continue; fi
  src=$(bundle_source "$rel") || fail "cannot locate bundle source for $rel"
  mkdir -p "$stage/bundle/$(dirname "$rel")"
  cp "$src" "$stage/bundle/$rel"
done < "$stage/manifest"

if [ ! -e "$target_root/.intent/config.yaml" ] && [ ! -L "$target_root/.intent/config.yaml" ]; then
  {
    printf 'protocol_version: "1.0"\nreview:\n  required: false\n  authorized_reviewers:'
    if [ "$reviewer_count" -eq 0 ]; then
      printf ' [] # TODO: add authorized reviewers before enabling approval gates\n'
    else
      printf '\n'
      for reviewer in $reviewers; do printf '    - "%s"\n' "$reviewer"; done
    fi
    printf 'policy:\n  protected_paths:\n'
    printf '    - "tests/**"\n    - "test/**"\n    - "spec/**"\n'
    printf '    - "**/*.test.*"\n    - "**/*.spec.*"\n    - "**/*_test.*"\n    - "**/test_*.py"\n'
    printf '  verify_command: ""\n  require_baseline: false\n'
  } > "$stage/bundle/.intent/config.yaml"
fi

check_directory() {
  path=$1
  if [ -L "$path" ]; then fail "symlinked managed directory: $path"; fi
  if [ -e "$path" ] && [ ! -d "$path" ]; then fail "managed path is not a directory: $path"; fi
}

upgrade_replaces() {
  case $1 in
    .intent/config.yaml|.intent/PROJECT.md) return 1 ;;
    *) return 0 ;;
  esac
}

upgrade_pending() {
  rel=$1
  staged=$stage/bundle/$rel
  [ -f "$staged" ] || return 1
  [ -e "$target_root/$rel" ] || return 1
  cmp -s "$staged" "$target_root/$rel" && return 1
  upgrade_replaces "$rel"
}

for dir in .intent .intent/protocol .intent/schemas .intent/schemas/v1 .intent/decisions .intent/changes .intent/changes/TEMPLATE .intent/scripts; do
  check_directory "$target_root/$dir"
done

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  dest=$target_root/$rel
  [ ! -L "$dest" ] || fail "symlinked managed file: $rel"
  if [ -e "$dest" ]; then
    [ -f "$dest" ] || fail "managed destination is not a regular file: $rel"
    staged=$stage/bundle/$rel
    if [ -f "$staged" ] && ! cmp -s "$staged" "$dest" && [ "$upgrade" -eq 0 ]; then
      fail "managed file differs from installer template: $rel (preserved; resolve manually)"
    fi
  fi
done < "$stage/manifest"

agents=$target_root/AGENTS.md
agents_plan=$stage/AGENTS.md
block=$intent_root/install/templates/AGENTS.block.md
[ ! -L "$agents" ] || fail "root AGENTS.md is a symlink; refusing to follow it"
if [ -e "$agents" ] && [ ! -f "$agents" ]; then fail "root AGENTS.md is not a regular file"; fi

if [ -f "$agents" ]; then
  LC_ALL=C awk '
    {
      marker = $0
      sub(/\r$/, "", marker)
      if (marker == "<!-- intent:managed:start -->") { starts++; start_line = NR }
      if (marker == "<!-- intent:managed:end -->") { ends++; end_line = NR }
    }
    END {
      if (starts != ends || starts > 1 || ends > 1 || (starts == 1 && start_line >= end_line)) exit 2
      if (starts == 1) print "replace"
      else print "append"
    }
  ' "$agents" > "$stage/marker-state" || fail "AGENTS.md has duplicate, unmatched, or malformed Intent markers"
  marker_state=$(sed -n '1p' "$stage/marker-state")
  if [ "$marker_state" = replace ]; then
    LC_ALL=C awk '
      {
        marker = $0
        sub(/\r$/, "", marker)
        if (marker == "<!-- intent:managed:start -->") start_line = NR
        if (marker == "<!-- intent:managed:end -->") end_line = NR
      }
      { lengths[NR] = length($0) }
      END {
        offset = 0
        for (i = 1; i < start_line; i++) offset += lengths[i] + 1
        prefix_bytes = offset + lengths[start_line] + 1
        offset = 0
        for (i = 1; i < end_line; i++) offset += lengths[i] + 1
        printf "%d %d\n", prefix_bytes, offset
      }
    ' "$agents" > "$stage/marker-offsets"
    read prefix_bytes suffix_offset < "$stage/marker-offsets"
    dd if="$agents" of="$agents_plan" bs=1 count="$prefix_bytes" 2>/dev/null
    sed '1d;$d' "$block" >> "$agents_plan"
    dd if="$agents" bs=1 skip="$suffix_offset" 2>/dev/null >> "$agents_plan"
  else
    cp "$agents" "$agents_plan"
    last_byte=$(tail -c 1 "$agents" | od -An -t x1 | tr -d ' \n')
    [ -z "$last_byte" ] || [ "$last_byte" = 0a ] || printf '\n' >> "$agents_plan"
    cat "$block" >> "$agents_plan"
  fi
else
  cp "$block" "$agents_plan"
fi

agents_action=unchanged
if [ ! -e "$agents" ] || ! cmp -s "$agents_plan" "$agents"; then agents_action=update; fi

if [ "$dry_run" -eq 1 ]; then
  say "validated target $target_root"
  if [ "$config_was_present" -eq 1 ]; then say "preserve existing .intent/config.yaml; supplied reviewer IDs are not applied"; fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dest=$target_root/$rel
    if [ ! -e "$dest" ]; then
      say "create $rel"
    elif [ "$upgrade" -eq 1 ] && upgrade_pending "$rel"; then
      say "replace $rel"
    else
      say "keep existing $rel"
    fi
  done < "$stage/manifest"
  [ "$agents_action" = unchanged ] || say "update managed section of AGENTS.md"
  say "dry run complete; no repository files were changed"
  exit 0
fi

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  dest=$target_root/$rel
  staged=$stage/bundle/$rel
  if [ ! -e "$dest" ] && [ -f "$staged" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$staged" "$dest"
    say "created $rel"
  elif [ "$upgrade" -eq 1 ] && upgrade_pending "$rel"; then
    cp "$staged" "$dest"
    say "replaced $rel"
  fi
done < "$stage/manifest"
if [ "$agents_action" = update ]; then cp "$agents_plan" "$agents"; say "updated managed section of AGENTS.md"; fi

say "installed Intent protocol 1.0 in $target_root"
if [ "$config_was_present" -eq 1 ]; then say "preserved existing .intent/config.yaml; CODEOWNERS and supplied reviewer IDs were not applied"; fi
if [ "$reviewer_count" -eq 0 ]; then say "TODO: no CODEOWNERS owners found; add authorized reviewers before enabling approval gates"; fi
say "complete .intent/PROJECT.md; approval remains disabled by default"
say "guidance is not technical write enforcement; no files were staged or committed"
