#!/bin/sh

set -eu

repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
migrator=$repo_root/scripts/migrate-v1.sh
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/intent-migrate-tests.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM
passed=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    tr -d '\r' < "$1" | sha256sum | awk '{print $1}'
  else
    tr -d '\r' < "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "expected '$2' in $1"; }
assert_absent() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected path absent: $1"; }
assert_file() { [ -f "$1" ] || fail "expected file: $1"; }

run_migrator() { sh "$migrator" "$@" > "$temp_root/out" 2>&1; }

expect_pass() {
  desc=$1
  shift
  if run_migrator "$@"; then
    pass "$desc"
  else
    fail "$desc (expected pass; output: $(cat "$temp_root/out"))"
  fi
}

expect_fail() {
  desc=$1
  needle=$2
  shift 2
  if run_migrator "$@"; then
    fail "$desc (expected failure, migrator passed)"
  fi
  grep -Fq -- "$needle" "$temp_root/out" || fail "$desc (missing message '$needle'; output: $(cat "$temp_root/out"))"
  pass "$desc"
}

expect_pass_cmd() {
  desc=$1
  shift
  if "$@" > "$temp_root/out" 2>&1; then
    pass "$desc"
  else
    fail "$desc (expected pass; output: $(cat "$temp_root/out"))"
  fi
}

new_v1_repo() {
  dir=$1
  mkdir -p "$dir/.intent/protocol" "$dir/.intent/schemas/v1" "$dir/.intent/changes/TEMPLATE" \
    "$dir/.intent/scripts" "$dir/.intent/decisions" \
    "$dir/.intent/changes/CHG-0001" "$dir/.intent/changes/CHG-0002"
  git -C "$dir" init -q

  printf 'v1 guidance\n' > "$dir/.intent/AGENT_GUIDE.md"
  printf 'v1 readme\n' > "$dir/.intent/README.md"
  printf 'user project facts\n' > "$dir/.intent/PROJECT.md"
  printf 'stale v1 protocol\n' > "$dir/.intent/protocol/v1.md"
  printf '{}\n' > "$dir/.intent/schemas/v1/change.schema.json"
  printf '{}\n' > "$dir/.intent/schemas/v1/config.schema.json"
  printf '{}\n' > "$dir/.intent/schemas/v1/review.schema.json"
  printf 'v1 decisions readme\n' > "$dir/.intent/decisions/README.md"
  printf 'local decision\n' > "$dir/.intent/decisions/keep.md"
  printf 'v1 verifier stub\n' > "$dir/.intent/scripts/verify-change.sh"
  printf 'old template\n' > "$dir/.intent/changes/TEMPLATE/change.yaml.tmpl"
  printf 'template proposal\n' > "$dir/.intent/changes/TEMPLATE/proposal.md"
  printf 'template conformance\n' > "$dir/.intent/changes/TEMPLATE/conformance.md"
  printf 'template review\n' > "$dir/.intent/changes/TEMPLATE/review.yaml.tmpl"

  cat > "$dir/.intent/config.yaml" <<'EOF'
protocol_version: "1.0"
review:
  required: false
  authorized_reviewers: []
policy:
  protected_paths:
    - "tests/**"
  verify_command: "make test"
  require_baseline: false
EOF

  cat > "$dir/.intent/changes/CHG-0001/proposal.md" <<'EOF'
# Change intent

## Outcome

Tour for first-time visitors. Existing behavior stays.

## Verification

Checks passed.

Inline decision text.
EOF
  digest1=sha256:$(sha256_file "$dir/.intent/changes/CHG-0001/proposal.md")
  cat > "$dir/.intent/changes/CHG-0001/change.yaml" <<EOF
protocol_version: "1.0"
id: "CHG-0001"
title: "First fixture change"
status: "complete"
created_at: "2026-10-01T10:00:00Z"
request: "First fixture request."
proposal:
  path: "proposal.md"
  revision: 1
  digest: "$digest1"
scope:
  included:
    - "Tour for first-time visitors."
    - "An outcome only present in the change.yaml mirror."
  excluded:
    - "Replay affordances stay out."
  paths:
    - "src/**"
preserved:
  - "Existing behavior stays."
test_changes:
  - path: "tests/x.test.js"
    kind: modified
    reason: "fixture reason"
decisions:
  - "Inline decision text."
review_required: false
EOF
  printf '# Conformance record\n\nOutcome: verified.\n' > "$dir/.intent/changes/CHG-0001/conformance.md"

  cat > "$dir/.intent/changes/CHG-0002/proposal.md" <<'EOF'
# Change intent

## Outcome

Second fixture change body.
EOF
  digest2=sha256:$(sha256_file "$dir/.intent/changes/CHG-0002/proposal.md")
  cat > "$dir/.intent/changes/CHG-0002/change.yaml" <<EOF
protocol_version: "1.0"
id: "CHG-0002"
title: "Second fixture change"
status: "complete"
created_at: "2026-10-02T10:00:00Z"
request: "Second fixture request."
proposal:
  path: "proposal.md"
  revision: 1
  digest: "$digest2"
scope:
  included:
    - "Second fixture change body."
  excluded: []
  paths:
    - "src/app.js"
preserved: []
test_changes: []
decisions: []
review_required: true
EOF
  cat > "$dir/.intent/changes/CHG-0002/review.yaml" <<EOF
protocol_version: "1.0"
change_id: "CHG-0002"
reviews:
  - reviewer_id: "reviewer:maintainer-1"
    reviewer_authority: "repository-policy:maintainer"
    decision: "approved"
    proposal_digest: "$digest2"
    reviewed_at: "2026-10-02T11:00:00Z"
    constraints: []
EOF
  printf '# Conformance record\n\nOutcome: verified.\n' > "$dir/.intent/changes/CHG-0002/conformance.md"

  printf 'outside\n<!-- intent:managed:start -->\nold\n<!-- intent:managed:end -->\n' > "$dir/AGENTS.md"

  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm base
  base_sha=$(git -C "$dir" rev-parse HEAD)
}

# The happy path: migrate with --ci, then verify every record.
repo=$temp_root/migrate
new_v1_repo "$repo"
digest1=sha256:$(sha256_file "$repo/.intent/changes/CHG-0001/proposal.md")
agents_before=$(cat "$repo/AGENTS.md")
expect_pass 'migration succeeds' --target "$repo" --ci
assert_contains "$temp_root/out" 'migrated .intent/changes/CHG-0001'
assert_contains "$temp_root/out" '_v1-notes.md'
expect_pass_cmd 'migrated CHG-0001 passes the v2 verifier' sh "$repo/.intent/scripts/verify-change.sh" --change .intent/changes/CHG-0001 --base "$base_sha" --head "$base_sha" --command 'true' --root "$repo"
expect_pass_cmd 'migrated CHG-0002 passes with its approval' sh "$repo/.intent/scripts/verify-change.sh" --change .intent/changes/CHG-0002 --base "$base_sha" --head "$base_sha" --command 'true' --root "$repo"
assert_contains "$repo/.intent/changes/CHG-0001/proposal.md" "  digest: \"$digest1\""
assert_file "$repo/.intent/changes/CHG-0001/_v1-notes.md"
assert_contains "$repo/.intent/changes/CHG-0001/_v1-notes.md" 'An outcome only present in the change.yaml mirror.'
assert_contains "$repo/.intent/changes/CHG-0001/_v1-notes.md" 'Replay affordances stay out.'
if grep -Fq 'Tour for first-time visitors.' "$repo/.intent/changes/CHG-0001/_v1-notes.md"; then fail 'contained mirror item was archived'; fi
assert_absent "$repo/.intent/changes/CHG-0002/_v1-notes.md"
assert_contains "$repo/.intent/PROJECT.md" 'user project facts'
assert_contains "$repo/.intent/decisions/keep.md" 'local decision'
assert_absent "$repo/.intent/protocol/v1.md"
assert_absent "$repo/.intent/schemas/v1"
assert_absent "$repo/.intent/changes/TEMPLATE/change.yaml.tmpl"
assert_file "$repo/.intent/protocol/v2.md"
assert_file "$repo/.intent/scripts/verify-records.sh"
assert_file "$repo/.github/workflows/intent-verify.yml"
if [ "$agents_before" != "$(cat "$repo/AGENTS.md")" ]; then fail 'migrator altered AGENTS.md'; fi
assert_contains "$repo/.intent/config.yaml" 'protocol_version: "2.0"'
assert_contains "$repo/.intent/config.yaml" 'make test'
expect_fail 'a second migration is refused' 'already on Intent protocol 2.0' --target "$repo"

# A dirty tree is refused before any write.
repo=$temp_root/dirty
new_v1_repo "$repo"
printf 'dirty\n' >> "$repo/.intent/PROJECT.md"
expect_fail 'dirty tree is refused' 'not clean' --target "$repo"
assert_absent "$repo/.intent/protocol/v2.md"

# A missing proposal.md is reported in preflight.
repo=$temp_root/missing
new_v1_repo "$repo"
rm "$repo/.intent/changes/CHG-0001/proposal.md"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm drop
expect_fail 'missing proposal.md is reported' 'missing proposal.md' --target "$repo"
assert_absent "$repo/.intent/protocol/v2.md"

# --dry-run writes nothing.
repo=$temp_root/dry-run
new_v1_repo "$repo"
expect_pass 'dry run succeeds' --target "$repo" --dry-run
assert_contains "$temp_root/out" 'would migrate .intent/changes/CHG-0001'
assert_absent "$repo/.intent/protocol/v2.md"
assert_absent "$repo/.intent/changes/CHG-0001/_v1-notes.md"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail 'dry run changed the working tree'

printf 'All %s migration scenarios passed.\n' "$passed"
