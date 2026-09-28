#!/bin/sh

set -eu

repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
installer=$repo_root/scripts/install.sh
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/intent-installer-tests.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM
passed=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() { [ -f "$1" ] || fail "expected file: $1"; }
assert_absent() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected path absent: $1"; }
assert_contains() { grep -F "$2" "$1" >/dev/null || fail "expected '$2' in $1"; }
assert_not_contains() { if grep -F "$2" "$1" >/dev/null; then fail "unexpected '$2' in $1"; fi; }
new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q || fail "could not initialize fixture Git repository"
}
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

# Inferred root from a nested working directory, first install, user text preservation,
# source parity, and a repeat install that replaces only the marked block.
repo=$temp_root/basic
new_repo "$repo"
mkdir -p "$repo/subdir"
printf 'Keep this project guidance.\n' > "$repo/AGENTS.md"
(cd "$repo/subdir" && sh "$installer" >/dev/null)
assert_contains "$repo/AGENTS.md" 'Keep this project guidance.'
assert_contains "$repo/AGENTS.md" '<!-- intent:managed:start -->'
assert_contains "$repo/.intent/config.yaml" 'required: false'
assert_contains "$repo/.intent/config.yaml" 'authorized_reviewers: [] # TODO: add authorized reviewers before enabling approval gates'
assert_contains "$repo/.intent/config.yaml" 'protected_paths:'
assert_contains "$repo/.intent/config.yaml" '"tests/**"'
assert_contains "$repo/.intent/config.yaml" 'verify_command: ""'
assert_contains "$repo/AGENTS.md" 'Follow `.intent/AGENT_GUIDE.md` to deliver the requested outcome'
for outcome in 'Proceed autonomously' '## Complete'; do
  assert_contains "$repo/.intent/AGENT_GUIDE.md" "$outcome"
done
cmp "$repo_root/install/templates/.intent/AGENT_GUIDE.md" "$repo/.intent/AGENT_GUIDE.md" || fail 'installed agent guide differs from template'
cmp "$repo_root/protocol/v1.md" "$repo/.intent/protocol/v1.md" || fail 'installed protocol differs from source'
for schema in config change review; do
  cmp "$repo_root/schemas/v1/$schema.schema.json" "$repo/.intent/schemas/v1/$schema.schema.json" || fail "installed $schema schema differs from source"
done
cmp "$repo_root/scripts/verify-change.sh" "$repo/.intent/scripts/verify-change.sh" || fail 'installed verifier differs from source'
cmp "$repo_root/install/templates/.intent/changes/TEMPLATE/conformance.md" "$repo/.intent/changes/TEMPLATE/conformance.md" || fail 'installed conformance template differs from source'
printf 'outside-before\r\n<!-- intent:managed:start -->\r\nold managed content\r\n<!-- intent:managed:end -->\r\noutside-after-without-final-newline' > "$repo/AGENTS.md"
printf 'outside-before\r\n<!-- intent:managed:start -->\r\n' > "$temp_root/expected-AGENTS.md"
sed '1d;$d' "$repo_root/install/templates/AGENTS.block.md" >> "$temp_root/expected-AGENTS.md"
printf '<!-- intent:managed:end -->\r\noutside-after-without-final-newline' >> "$temp_root/expected-AGENTS.md"
(cd "$repo" && sh "$installer" >/dev/null)
cmp "$temp_root/expected-AGENTS.md" "$repo/AGENTS.md" || fail 'replacement did not preserve bytes outside managed markers'
assert_not_contains "$repo/AGENTS.md" 'old managed content'
[ "$(grep -c '<!-- intent:managed:start -->' "$repo/AGENTS.md")" -eq 1 ] || fail 'repeat install duplicated marker'
pass 'inferred Git root, bundle parity, and managed block replacement'

# Dry-run and explicit target resolution leave a previously empty target unchanged.
repo=$temp_root/dry-run
new_repo "$repo"
mkdir -p "$repo/nested"
(cd "$temp_root" && sh "$installer" --target "$repo/nested" --dry-run >/dev/null)
assert_absent "$repo/.intent"
assert_absent "$repo/AGENTS.md"
(cd "$temp_root" && sh "$installer" --target "$repo/nested" >/dev/null)
assert_file "$repo/AGENTS.md"
assert_file "$repo/.intent/config.yaml"
pass 'explicit target root and no-write dry run'

# CODEOWNERS precedence, unique owner import, inline comments, and explicit additions.
repo=$temp_root/codeowners
new_repo "$repo"
mkdir -p "$repo/.github" "$repo/docs"
printf '* @org/global @alice\nsrc/** @org/team @alice # inline note\n' > "$repo/.github/CODEOWNERS"
printf '* @ignored/root\n' > "$repo/CODEOWNERS"
printf '* @ignored/docs\n' > "$repo/docs/CODEOWNERS"
(cd "$repo" && sh "$installer" --reviewer '@manual/reviewer' >/dev/null)
assert_contains "$repo/.intent/config.yaml" '"@org/global"'
assert_contains "$repo/.intent/config.yaml" '"@alice"'
assert_contains "$repo/.intent/config.yaml" '"@org/team"'
assert_contains "$repo/.intent/config.yaml" '"@manual/reviewer"'
assert_not_contains "$repo/.intent/config.yaml" '@ignored/'
[ "$(grep -c '"@alice"' "$repo/.intent/config.yaml")" -eq 1 ] || fail 'duplicate CODEOWNERS owner was imported more than once'
assert_not_contains "$repo/.intent/config.yaml" 'inline note'
pass 'CODEOWNERS precedence and distinct owner import'

repo=$temp_root/docs-codeowners
new_repo "$repo"
mkdir -p "$repo/docs"
printf '* @docs-owner\n' > "$repo/docs/CODEOWNERS"
(cd "$repo" && sh "$installer" >/dev/null)
assert_contains "$repo/.intent/config.yaml" '"@docs-owner"'
pass 'docs CODEOWNERS fallback is discovered'

# Reviewer IDs are optional; supplied IDs are validated before target writes.
repo=$temp_root/no-reviewer
new_repo "$repo"
(cd "$repo" && sh "$installer" </dev/null >/dev/null)
assert_contains "$repo/.intent/config.yaml" 'authorized_reviewers: []'
pass 'autonomous default installs without prompts or reviewer IDs'
repo=$temp_root/optional-reviewer
new_repo "$repo"
(cd "$repo" && sh "$installer" --reviewer 'team:core' >/dev/null)
assert_contains "$repo/.intent/config.yaml" 'required: false'
assert_contains "$repo/.intent/config.yaml" '"team:core"'
pass 'optional reviewer is recorded without enabling a universal approval gate'
repo=$temp_root/reviewer-validation
new_repo "$repo"
if (cd "$repo" && sh "$installer" --reviewer bad --reviewer bad >/dev/null 2>&1); then fail 'duplicate reviewer unexpectedly succeeded'; fi
if (cd "$repo" && sh "$installer" --reviewer 'bad id' >/dev/null 2>&1); then fail 'unsafe reviewer unexpectedly succeeded'; fi
assert_absent "$repo/.intent"
pass 'optional reviewer validation fails before writes'

# A managed-file conflict aborts the entire install, including AGENTS.md.
repo=$temp_root/conflict
new_repo "$repo"
mkdir -p "$repo/.intent"
printf 'user-owned content\n' > "$repo/.intent/PROJECT.md"
if (cd "$repo" && sh "$installer" --reviewer reviewer-1 >/dev/null 2>&1); then fail 'managed-file conflict unexpectedly succeeded'; fi
assert_contains "$repo/.intent/PROJECT.md" 'user-owned content'
assert_absent "$repo/.intent/README.md"
assert_absent "$repo/AGENTS.md"
pass 'managed-file conflict aborts before any install writes'

# Symlinked managed paths are never followed.
repo=$temp_root/symlink
new_repo "$repo"
mkdir -p "$repo/.intent"
printf 'outside\n' > "$temp_root/outside"
ln -s "$temp_root/outside" "$repo/.intent/PROJECT.md"
if (cd "$repo" && sh "$installer" --reviewer reviewer-1 >/dev/null 2>&1); then fail 'symlink conflict unexpectedly succeeded'; fi
assert_absent "$repo/.intent/README.md"
assert_absent "$repo/AGENTS.md"
assert_contains "$temp_root/outside" 'outside'
pass 'symlinked managed destination is rejected safely'

repo=$temp_root/agents-symlink
new_repo "$repo"
printf 'outside guidance\n' > "$temp_root/outside-AGENTS.md"
ln -s "$temp_root/outside-AGENTS.md" "$repo/AGENTS.md"
if (cd "$repo" && sh "$installer" --reviewer reviewer-1 >/dev/null 2>&1); then fail 'AGENTS.md symlink unexpectedly succeeded'; fi
assert_absent "$repo/.intent"
assert_contains "$temp_root/outside-AGENTS.md" 'outside guidance'
pass 'symlinked root AGENTS.md is rejected without following it'

# Malformed marker pairs abort before creating the .intent bundle.
repo=$temp_root/malformed
new_repo "$repo"
printf 'before\n<!-- intent:managed:start -->\nno end\n' > "$repo/AGENTS.md"
if (cd "$repo" && sh "$installer" --reviewer reviewer-1 >/dev/null 2>&1); then fail 'unmatched marker unexpectedly succeeded'; fi
assert_contains "$repo/AGENTS.md" 'before'
assert_absent "$repo/.intent"
pass 'malformed managed markers abort before writes'

repo=$temp_root/no-git
mkdir -p "$repo"
if (cd "$repo" && sh "$installer" --reviewer reviewer-1 >/dev/null 2>&1); then fail 'non-Git target unexpectedly succeeded'; fi
assert_absent "$repo/.intent"
assert_absent "$repo/AGENTS.md"
pass 'non-Git targets fail before writes'

# Unrelated data and a user's existing config survive successful installs.
repo=$temp_root/unrelated
new_repo "$repo"
mkdir -p "$repo/.intent/notes"
printf 'local note\n' > "$repo/.intent/notes/keep.md"
printf 'protocol_version: "1.0"\nreview:\n  required: true\n  authorized_reviewers:\n    - "preexisting"\n' > "$repo/.intent/config.yaml"
(cd "$repo" && sh "$installer" --reviewer ignored-for-existing-config >/dev/null)
assert_contains "$repo/.intent/notes/keep.md" 'local note'
assert_contains "$repo/.intent/config.yaml" '"preexisting"'
assert_not_contains "$repo/.intent/config.yaml" 'ignored-for-existing-config'
pass 'unrelated files and existing config are preserved'

# Upgrade replaces managed files while preserving repository content.
repo=$temp_root/upgrade
new_repo "$repo"
(cd "$repo" && sh "$installer" >/dev/null)
printf 'stale protocol\n' > "$repo/.intent/protocol/v1.md"
printf 'user project facts\n' > "$repo/.intent/PROJECT.md"
printf 'local decision\n' > "$repo/.intent/decisions/keep.md"
if (cd "$repo" && sh "$installer" >/dev/null 2>&1); then fail 'differing managed file unexpectedly reinstalled without --upgrade'; fi
(cd "$repo" && sh "$installer" --upgrade --dry-run > "$temp_root/upgrade-dry")
assert_contains "$temp_root/upgrade-dry" 'replace .intent/protocol/v1.md'
assert_contains "$temp_root/upgrade-dry" 'keep existing .intent/PROJECT.md'
assert_contains "$repo/.intent/protocol/v1.md" 'stale protocol'
(cd "$repo" && sh "$installer" --upgrade >/dev/null)
cmp "$repo_root/protocol/v1.md" "$repo/.intent/protocol/v1.md" || fail 'upgrade did not replace the protocol file'
assert_contains "$repo/.intent/PROJECT.md" 'user project facts'
assert_contains "$repo/.intent/decisions/keep.md" 'local decision'
assert_contains "$repo/.intent/config.yaml" 'protocol_version: "1.0"'
pass 'upgrade replaces managed files and preserves repository content'

printf 'All %s installer scenarios passed.\n' "$passed"
