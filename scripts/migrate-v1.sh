#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: sh scripts/migrate-v1.sh [--target DIR] [--dry-run] [--ci]

Migrate an Intent protocol 1.0 installation to v2 in one deliberate pass:
change.yaml fields move into proposal.md front matter (bodies and digests are
preserved byte for byte), v1-only managed files are removed, and the v2 bundle
replaces the managed files. config.yaml keeps its policy and review values;
PROJECT.md, decisions, records' evidence, and AGENTS.md are left alone.

Options:
  --target DIR   Repository or directory inside the target Git repository
  --dry-run      Print the complete plan without writing anything
  --ci           Install .github/workflows/intent-verify.yml when it is absent
  --help         Show this help

The working tree must be clean. Nothing is staged or committed.
EOF
}

fail() {
  printf 'migrate-v1: error: %s\n' "$1" >&2
  exit 1
}

say() {
  printf 'migrate-v1: %s\n' "$1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    tr -d '\r' < "$1" | sha256sum | awk '{print $1}'
  else
    tr -d '\r' < "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

top_scalar() {
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

proposal_value() {
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

scope_items() {
  awk -v key="$1" '
    { sub(/\r$/, "") }
    /^scope:/ { in_scope = 1; in_list = 0; next }
    in_scope && /^[^[:space:]]/ { in_scope = 0; in_list = 0 }
    in_scope && /^[[:space:]]+[A-Za-z_]+:/ {
      if ($0 ~ ("^[[:space:]]+" key ":[[:space:]]*")) { in_list = 1 } else { in_list = 0 }
      next
    }
    in_scope && in_list && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      if (value != "") print value
      next
    }
  ' "$2"
}

top_items() {
  awk -v key="$1" '
    { sub(/\r$/, "") }
    index($0, key ":") == 1 { in_list = 1; next }
    /^[^[:space:]]/ { in_list = 0 }
    in_list && /^[[:space:]]*-[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^"|"$/, "", value)
      if (value != "") print value
      next
    }
  ' "$2"
}

test_change_entries() {
  awk '
    { sub(/\r$/, "") }
    /^test_changes:/ { in_list = 1; next }
    in_list && /^[^[:space:]]/ { in_list = 0 }
    in_list && /^[[:space:]]*-[[:space:]]*path:/ { got = 1; path = $0; sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", path); gsub(/^"|"$/, "", path); kind = ""; reason = ""; next }
    in_list && got && /^[[:space:]]+kind:/ { kind = $0; sub(/^[[:space:]]+kind:[[:space:]]*/, "", kind); gsub(/^"|"$/, "", kind); next }
    in_list && got && /^[[:space:]]+reason:/ { reason = $0; sub(/^[[:space:]]+reason:[[:space:]]*/, "", reason); gsub(/^"|"$/, "", reason); print path "\t" kind "\t" reason; got = 0; next }
  ' "$1"
}

target_arg=
target_set=0
dry_run=0
ci=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || fail "--target requires a directory"
      [ "$target_set" -eq 0 ] || fail "--target may only be specified once"
      target_arg=$2
      target_set=1
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --ci)
      ci=1
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

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P) || fail "cannot locate scripts directory"
[ -f "$script_dir/lib-bundle.sh" ] || fail "cannot locate scripts/lib-bundle.sh"
. "$script_dir/lib-bundle.sh"

if [ "$target_set" -eq 1 ]; then
  [ -d "$target_arg" ] || fail "target directory does not exist: $target_arg"
  root=$(git -C "$target_arg" rev-parse --show-toplevel 2>/dev/null) || fail "target is not inside a Git repository: $target_arg"
else
  root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "current directory is not inside a Git repository; use --target DIR"
fi
root=$(CDPATH= cd "$root" && pwd -P) || fail "cannot resolve target Git root"

config=$root/.intent/config.yaml
[ -f "$config" ] || fail "target does not look like an Intent v1 installation"
if grep -Eq '^protocol_version:[[:space:]]*"?2\.0"?[[:space:]]*$' "$config"; then
  fail "target is already on Intent protocol 2.0"
fi
if ! grep -Eq '^protocol_version:[[:space:]]*"?1\.0"?[[:space:]]*$' "$config" || [ ! -f "$root/.intent/protocol/v1.md" ]; then
  fail "target does not look like an Intent v1 installation"
fi

[ -z "$(git -C "$root" status --porcelain)" ] || fail "working tree is not clean; commit or stash before migrating"

invalid=
for dir in "$root"/.intent/changes/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  [ "$name" = TEMPLATE ] && continue
  if [ ! -f "$dir/proposal.md" ] || [ ! -f "$dir/change.yaml" ]; then
    invalid="${invalid}${invalid:+ }$name"
  fi
done
[ -z "$invalid" ] || fail "change records missing proposal.md or change.yaml: $invalid"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/intent-migrate.XXXXXX") || fail "cannot create temporary directory"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# Validation pass: every recorded digest must equal the proposal body digest,
# and each record's front matter and notes are staged before any write.
: > "$tmp/changes"
: > "$tmp/report"
for dir in "$root"/.intent/changes/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  [ "$name" = TEMPLATE ] && continue
  cy=$dir/change.yaml
  prop=$dir/proposal.md

  recorded=$(proposal_value digest "$cy")
  actual=sha256:$(sha256_file "$prop")
  [ "$recorded" = "$actual" ] || fail "$name recorded digest $recorded does not match its proposal body $actual"

  revision=$(proposal_value revision "$cy")
  [ -n "$revision" ] || revision=1

  fm=$tmp/fm-$name
  notes=$tmp/notes-$name
  : > "$notes"

  body_norm=$(tr -s '[:space:]' ' ' < "$prop" | sed 's/^ *//; s/ *$//')
  archive_unmatched() {
    items_file=$1
    label=$2
    unmatched=$tmp/unmatched
    : > "$unmatched"
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      item_norm=$(printf '%s' "$item" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')
      if printf '%s' "$body_norm" | grep -Fq -- "$item_norm"; then
        continue
      fi
      printf '%s\n' "$item" >> "$unmatched"
    done < "$items_file"
    if [ -s "$unmatched" ]; then
      {
        printf '## %s\n\n' "$label"
        sed 's/^/- /' "$unmatched"
        printf '\n'
      } >> "$notes"
    fi
  }

  scope_items included "$cy" > "$tmp/items"
  archive_unmatched "$tmp/items" "scope.included"
  scope_items excluded "$cy" > "$tmp/items"
  archive_unmatched "$tmp/items" "scope.excluded"
  top_items preserved "$cy" > "$tmp/items"
  archive_unmatched "$tmp/items" "preserved"
  top_items decisions "$cy" > "$tmp/items"
  archive_unmatched "$tmp/items" "decisions"

  paths=$(scope_items paths "$cy")
  entries=$(test_change_entries "$cy")

  {
    printf '%s\n' '---'
    printf 'protocol_version: "2.0"\n'
    printf 'id: "%s"\n' "$name"
    printf 'title: "%s"\n' "$(top_scalar title "$cy")"
    printf 'status: "%s"\n' "$(top_scalar status "$cy")"
    printf 'created_at: "%s"\n' "$(top_scalar created_at "$cy")"
    printf 'request: "%s"\n' "$(top_scalar request "$cy")"
    printf 'proposal:\n  revision: %s\n  digest: "%s"\n' "$revision" "$recorded"
    if [ -n "$paths" ]; then
      printf 'scope:\n  paths:\n'
      printf '%s\n' "$paths" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf '    - "%s"\n' "$p"
      done
    else
      printf 'scope:\n  paths: []\n'
    fi
    if [ -n "$entries" ]; then
      printf 'test_changes:\n'
      printf '%s\n' "$entries" | while IFS="$(printf '\t')" read -r p k r; do
        printf '  - path: "%s"\n    kind: "%s"\n    reason: "%s"\n' "$p" "$k" "$r"
      done
    else
      printf 'test_changes: []\n'
    fi
    printf 'links:\n  related: []\n  supersedes: []\n  decisions: []\n'
    printf 'review_required: %s\n' "$(top_scalar review_required "$cy")"
    printf '%s\n' '---'
  } > "$fm"

  cat "$fm" "$prop" > "$tmp/new-$name"

  notes_items=0
  if [ -s "$notes" ]; then
    notes_items=$(grep -c '^- ' "$notes" || true)
  fi
  if [ "$notes_items" -gt 0 ]; then
    printf '%s|%s|%s\n' "$name" "$notes_items" "notes" >> "$tmp/changes"
  else
    printf '%s|0|clean\n' "$name" >> "$tmp/changes"
  fi
done

# Write pass.
while IFS='|' read -r name notes_items state; do
  [ -n "$name" ] || continue
  dir=$root/.intent/changes/$name
  if [ "$dry_run" -eq 1 ]; then
    if [ "$state" = notes ]; then
      say "would migrate .intent/changes/$name (digest unchanged, $notes_items item(s) archived to _v1-notes.md)"
    else
      say "would migrate .intent/changes/$name (digest unchanged, no notes needed)"
    fi
  else
    cp "$tmp/new-$name" "$dir/proposal.md"
    if [ "$state" = notes ]; then
      cp "$tmp/notes-$name" "$dir/_v1-notes.md"
      say "migrated .intent/changes/$name (digest unchanged, $notes_items item(s) archived to _v1-notes.md)"
    else
      say "migrated .intent/changes/$name (digest unchanged, no notes needed)"
    fi
  fi
done < "$tmp/changes"

count=$(grep -c . "$tmp/changes" || true)
if [ "$count" -eq 0 ]; then
  say "no change records found"
fi

# Bundle: v2 managed files replace the v1 bundle; PROJECT.md and config.yaml
# keep repository-owned content.
manifest=$intent_root/install/manifest.txt
[ -f "$manifest" ] || fail "cannot locate install/manifest.txt"
bundle_count=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    .intent/config.yaml|.intent/PROJECT.md) continue ;;
  esac
  src=$(bundle_source "$rel") || fail "cannot locate bundle source for $rel"
  bundle_count=$((bundle_count + 1))
  if [ "$dry_run" -eq 1 ]; then
    continue
  fi
  mkdir -p "$(dirname "$root/$rel")"
  cp "$src" "$root/$rel"
done < "$manifest"

removed_count=0
for rel in .intent/protocol/v1.md .intent/changes/TEMPLATE/change.yaml.tmpl; do
  if [ -e "$root/$rel" ]; then
    removed_count=$((removed_count + 1))
    [ "$dry_run" -eq 1 ] || rm -f "$root/$rel"
  fi
done
if [ -d "$root/.intent/schemas/v1" ]; then
  removed_count=$((removed_count + 1))
  if [ "$dry_run" -eq 1 ]; then
    :
  else
    rm -f "$root/.intent/schemas/v1/"*.schema.json
    rmdir "$root/.intent/schemas/v1" 2>/dev/null || true
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  say "would replace $bundle_count managed bundle file(s) and remove $removed_count v1-only file(s)"
  say "would set protocol_version 2.0 in .intent/config.yaml"
else
  sed 's/^protocol_version:[[:space:]]*.*$/protocol_version: "2.0"/' "$config" > "$tmp/config.new"
  grep -q '^protocol_version: "2.0"$' "$tmp/config.new" || fail "could not update protocol_version in .intent/config.yaml"
  mv "$tmp/config.new" "$config"
  say "replaced $bundle_count managed bundle file(s) and removed $removed_count v1-only file(s)"
  say "set protocol_version 2.0 in .intent/config.yaml"
fi

if [ -f "$root/AGENTS.md" ]; then
  starts=$(grep -c '^<!-- intent:managed:start -->$' "$root/AGENTS.md" || true)
  ends=$(grep -c '^<!-- intent:managed:end -->$' "$root/AGENTS.md" || true)
  if [ "$starts" -eq 1 ] && [ "$ends" -eq 1 ]; then
    say "AGENTS.md managed block is intact"
  else
    printf 'migrate-v1: warning: AGENTS.md managed block markers are missing or malformed; left unchanged\n' >&2
  fi
fi

if [ "$ci" -eq 1 ]; then
  ci_rel=.github/workflows/intent-verify.yml
  ci_src=$(bundle_source "$ci_rel") || fail "cannot locate bundle source for $ci_rel"
  ci_dest=$root/$ci_rel
  ci_action=create
  if [ -e "$ci_dest" ]; then
    if cmp -s "$ci_src" "$ci_dest"; then
      ci_action=keep
    else
      fail "managed file differs from installer template: $ci_rel (preserved; resolve manually)"
    fi
  fi
  if [ "$ci_action" = create ]; then
    if [ "$dry_run" -eq 1 ]; then
      say "would create $ci_rel"
    else
      mkdir -p "$(dirname "$ci_dest")"
      cp "$ci_src" "$ci_dest"
      say "created $ci_rel"
    fi
  else
    say "kept existing $ci_rel"
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  say "dry run complete; no files were changed"
else
  say "migrated $count change record(s); nothing was staged or committed"
fi
