#!/bin/sh

set -eu

repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
verifier=$repo_root/scripts/verify-change.sh
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/intent-verifier-tests.XXXXXX")
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

new_fixture() {
  dir=$1
  mkdir -p "$dir/tests" "$dir/src" "$dir/checks" "$dir/.intent/changes/CHG-0001"
  git -C "$dir" init -q
  printf 'def test_existing():\n    assert app() == 1\n' > "$dir/tests/test_app.py"
  printf 'def app():\n    return 1\n' > "$dir/src/app.py"
  printf '#[test]\nfn existing() {}\n' > "$dir/src/suite_inline.rs"
  printf 'check body\n' > "$dir/checks/sample.txt"
  printf '# fixture\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm base
  base_sha=$(git -C "$dir" rev-parse HEAD)
}

make_change() {
  dir=$1
  proposal_text=$2
  test_yaml=${3:-'test_changes: []'}
  scope_yaml=${4:-'  paths: []'}
  proposal=$dir/.intent/changes/CHG-0001/proposal.md
  printf '%s\n' "$proposal_text" > "$proposal"
  digest=$(sha256_file "$proposal")
  {
    printf 'protocol_version: "1.0"\n'
    printf 'id: CHG-0001\n'
    printf 'title: Fixture change\n'
    printf 'status: implementing\n'
    printf 'created_at: "2026-09-28T10:00:00Z"\n'
    printf 'request: Fixture request.\n'
    printf 'proposal:\n  path: proposal.md\n  revision: 1\n  digest: sha256:%s\n' "$digest"
    printf 'scope:\n  included:\n    - fixture outcome\n  excluded: []\n%s\n' "$scope_yaml"
    printf 'preserved: []\n%s\n' "$test_yaml"
    printf 'decisions: []\n'
    printf 'review_required: false\n'
  } > "$dir/.intent/changes/CHG-0001/change.yaml"
}

run_verifier() {
  sh "$verifier" "$@" > "$temp_root/out" 2>&1
}

expect_pass() {
  desc=$1
  shift
  if run_verifier "$@"; then
    pass "$desc"
  else
    fail "$desc (expected pass; output: $(cat "$temp_root/out"))"
  fi
}

expect_fail() {
  desc=$1
  needle=$2
  shift 2
  if run_verifier "$@"; then
    fail "$desc (expected failure, verifier passed)"
  fi
  grep -Fq -- "$needle" "$temp_root/out" || fail "$desc (missing message '$needle'; output: $(cat "$temp_root/out"))"
  pass "$desc"
}

declared_test_changes='test_changes:
  - path: "tests/test_app.py"
    kind: modified
    reason: "approved wording"'

flip_change() {
  file=$1
  shift
  sed "$@" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

drop_line() {
  file=$1
  pattern=$2
  grep -v "$pattern" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

write_review() {
  dir=$1
  digest=$2
  reviewer=$3
  decision=$4
  cat > "$dir/.intent/changes/CHG-0001/review.yaml" <<EOF
protocol_version: "1.0"
change_id: CHG-0001
reviews:
  - reviewer_id: $reviewer
    reviewer_authority: repository-policy:maintainer
    decision: $decision
    proposal_digest: $digest
    reviewed_at: "2026-09-28T10:30:00Z"
    constraints: []
EOF
}

write_approval_config() {
  mkdir -p "$1/.intent"
  cat > "$1/.intent/config.yaml" <<'EOF'
protocol_version: "1.0"
review:
  required: true
  authorized_reviewers:
    - "reviewer:maintainer-1"
EOF
}

change_digest_value() {
  printf 'sha256:%s\n' "$(sha256_file "$1/.intent/changes/CHG-0001/proposal.md")"
}

# A declared test modification and an in-scope source edit pass.
repo=$temp_root/declared
new_fixture "$repo"
make_change "$repo" 'Change app behavior.

Test changes: tests/test_app.py updated for the approved wording.' "$declared_test_changes"
printf 'def test_existing():\n    assert app() == 2\n' > "$repo/tests/test_app.py"
printf 'def app():\n    return 2\n' > "$repo/src/app.py"
expect_pass 'declared test change and source edit pass' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# An undeclared modification to a pre-existing test fails.
repo=$temp_root/undeclared
new_fixture "$repo"
make_change "$repo" 'Change app behavior without declaring a test change.'
printf 'def test_existing():\n    assert app() == 2\n' > "$repo/tests/test_app.py"
expect_fail 'undeclared test modification fails' 'tests/test_app.py' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A deleted pre-existing test fails.
repo=$temp_root/deleted
new_fixture "$repo"
make_change "$repo" 'Change app behavior without declaring a test change.'
rm "$repo/tests/test_app.py"
expect_fail 'deleted test fails' 'tests/test_app.py' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A new skip marker in an inline test fails even when the file is not protected.
repo=$temp_root/skip
new_fixture "$repo"
make_change "$repo" 'Change without declaring a test change.'
printf '#[test]\n#[ignore]\nfn existing() {}\n' > "$repo/src/suite_inline.rs"
expect_fail 'added skip marker fails' 'suite_inline.rs' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A proposal edited after the digest was recorded fails.
repo=$temp_root/digest
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
printf 'extra line\n' >> "$repo/.intent/changes/CHG-0001/proposal.md"
expect_fail 'proposal digest mismatch fails' 'digest' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A changed path outside the declared scope fails.
repo=$temp_root/scope
new_fixture "$repo"
make_change "$repo" 'Change app behavior.

Test changes: tests/test_app.py updated.' "$declared_test_changes" '  paths:
    - "src/**"'
printf 'def test_existing():\n    assert app() == 2\n' > "$repo/tests/test_app.py"
printf 'def app():\n    return 2\n' > "$repo/src/app.py"
expect_fail 'path outside declared scope fails' 'tests/test_app.py' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A failing verification command fails.
repo=$temp_root/command-fail
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
expect_fail 'failing verification command fails' 'verification command' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo" --command 'false'

# A passing verification command passes.
repo=$temp_root/command-pass
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
printf 'marker\n' > "$repo/marker.txt"
expect_pass 'passing verification command passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo" --command 'test -f marker.txt'

# A baseline that does not pass is reported.
repo=$temp_root/baseline
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
printf 'marker\n' > "$repo/marker.txt"
expect_fail 'failing baseline is reported' 'baseline' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo" --command 'test -f marker.txt' --baseline

# A proposal mention alone does not replace the test_changes mirror.
repo=$temp_root/mirror
new_fixture "$repo"
make_change "$repo" 'Change app behavior.

Test changes: tests/test_app.py updated.'
printf 'def test_existing():\n    assert app() == 2\n' > "$repo/tests/test_app.py"
expect_fail 'missing test_changes entry fails' 'test_changes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A newly added test file is allowed without declaration.
repo=$temp_root/added
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
printf 'def test_new():\n    assert True\n' > "$repo/tests/test_new.py"
expect_pass 'added test file passes without declaration' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Repository policy can protect additional paths.
repo=$temp_root/policy
new_fixture "$repo"
make_change "$repo" 'Change without declaring a protected edit.'
mkdir -p "$repo/.intent"
printf 'protocol_version: "1.0"\nreview:\n  required: false\n  authorized_reviewers: []\npolicy:\n  protected_paths:\n    - "checks/**"\n' > "$repo/.intent/config.yaml"
printf 'changed check body\n' > "$repo/checks/sample.txt"
expect_fail 'config protected path fails' 'checks/sample.txt' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Lifecycle state and structural invariants.
repo=$temp_root/unknown-state
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
flip_change "$repo/.intent/changes/CHG-0001/change.yaml" 's/^status: implementing/status: bogus/'
expect_fail 'unknown status fails' 'status' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/missing-field
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
drop_line "$repo/.intent/changes/CHG-0001/change.yaml" '^request:'
expect_fail 'missing required field fails' 'request' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/complete
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
flip_change "$repo/.intent/changes/CHG-0001/change.yaml" 's/^status: implementing/status: complete/'
expect_fail 'complete without conformance record fails' 'conformance.md' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"
printf '# Conformance record\n\nOutcome: verified.\n' > "$repo/.intent/changes/CHG-0001/conformance.md"
expect_pass 'complete with conformance record passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Approval evidence bound to the current proposal digest.
repo=$temp_root/approval-pass
new_fixture "$repo"
make_change "$repo" 'Approved change.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/change.yaml" 's/review_required: false/review_required: true/'
write_review "$repo" "$(change_digest_value "$repo")" 'reviewer:maintainer-1' approved
expect_pass 'approval for the current digest passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/approval-missing
new_fixture "$repo"
make_change "$repo" 'Change requiring approval.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/change.yaml" 's/review_required: false/review_required: true/'
expect_fail 'missing approval evidence fails' 'approval evidence' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/approval-stale
new_fixture "$repo"
make_change "$repo" 'Change requiring approval.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/change.yaml" 's/review_required: false/review_required: true/'
zeros=$(awk 'BEGIN { for (i = 0; i < 64; i++) printf "0" }')
write_review "$repo" "sha256:$zeros" 'reviewer:maintainer-1' approved
expect_fail 'stale approval digest fails' 'approval evidence' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/approval-unauthorized
new_fixture "$repo"
make_change "$repo" 'Change requiring approval.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/change.yaml" 's/review_required: false/review_required: true/'
write_review "$repo" "$(change_digest_value "$repo")" 'reviewer:stranger' approved
expect_fail 'unauthorized approval reviewer fails' 'authorized' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Auto-discovery and the digest helper.
repo=$temp_root/autodiscover
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
expect_pass 'single change is auto-discovered' --base "$base_sha" --root "$repo"

repo=$temp_root/print-digest
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
expected_digest=$(change_digest_value "$repo")
printed_digest=$(sh "$verifier" --change .intent/changes/CHG-0001 --root "$repo" --print-digest)
[ "$printed_digest" = "$expected_digest" ] || fail "print-digest mismatch: $printed_digest != $expected_digest"
pass 'print-digest matches the normalized proposal digest'

repo=$temp_root/print-digest-early
new_fixture "$repo"
printf 'Draft proposal.\n' > "$repo/.intent/changes/CHG-0001/proposal.md"
expected_digest=sha256:$(sha256_file "$repo/.intent/changes/CHG-0001/proposal.md")
printed_digest=$(sh "$verifier" --change .intent/changes/CHG-0001 --root "$repo" --print-digest)
[ "$printed_digest" = "$expected_digest" ] || fail "early print-digest mismatch: $printed_digest != $expected_digest"
pass 'print-digest works before change.yaml exists'

# Pinned schema validation runs when the toolchain is available.
if python3 -c 'import yaml, jsonschema' >/dev/null 2>&1; then
  repo=$temp_root/schema-invalid
  new_fixture "$repo"
  make_change "$repo" 'Change app behavior.'
  mkdir -p "$repo/.intent/schemas/v1"
  cp "$repo_root"/schemas/v1/*.schema.json "$repo/.intent/schemas/v1/"
  flip_change "$repo/.intent/changes/CHG-0001/change.yaml" 's/^  revision: 1/  revision: 0/'
  expect_fail 'schema-invalid record fails' 'change.yaml' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"
else
  printf 'skip - schema validation scenario (python3 with PyYAML and jsonschema unavailable)\n'
fi

printf 'All %s verifier scenarios passed.\n' "$passed"
