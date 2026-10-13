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

# Build a v2 change record: front matter + body. The body is kept beside the
# record as proposal.md.body so tests can recompute its digest.
make_change() {
  dir=$1
  body_text=$2
  test_yaml=${3-${TEST_YAML-'test_changes: []'}}
  scope_yaml=${4-${SCOPE_YAML-'  paths: []'}}
  proposal=$dir/.intent/changes/CHG-0001/proposal.md
  body=$dir/.intent/changes/CHG-0001/proposal.md.body
  printf '%s\n' "$body_text" > "$body"
  digest=$(sha256_file "$body")
  {
    printf '%s\n' '---'
    printf 'protocol_version: "2.0"\n'
    printf 'id: "CHG-0001"\n'
    printf 'title: "Fixture change"\n'
    printf 'status: "implementing"\n'
    printf 'created_at: "2026-10-13T10:00:00Z"\n'
    printf 'request: "Fixture request."\n'
    printf 'proposal:\n  revision: 1\n  digest: "sha256:%s"\n' "$digest"
    printf 'scope:\n%s\n' "$scope_yaml"
    printf '%s\n' "$test_yaml"
    printf 'review_required: false\n'
    printf '%s\n' '---'
    cat "$body"
  } > "$proposal"
}

run_verifier() { sh "$verifier" "$@" > "$temp_root/out" 2>&1; }

run_verifier_in() {
  dir=$1
  shift
  (cd "$dir" && sh "$verifier" "$@") > "$temp_root/out" 2>&1
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

expect_pass_in() {
  desc=$1
  dir=$2
  shift 2
  if run_verifier_in "$dir" "$@"; then
    pass "$desc"
  else
    fail "$desc (expected pass; output: $(cat "$temp_root/out"))"
  fi
}

expect_pass_with_output() {
  desc=$1
  needle=$2
  shift 2
  if run_verifier "$@"; then :; else fail "$desc (expected pass; output: $(cat "$temp_root/out"))"; fi
  grep -Fq -- "$needle" "$temp_root/out" || fail "$desc (missing output '$needle'; output: $(cat "$temp_root/out"))"
  pass "$desc"
}

expect_pass_without_output() {
  desc=$1
  needle=$2
  shift 2
  if run_verifier "$@"; then :; else fail "$desc (expected pass; output: $(cat "$temp_root/out"))"; fi
  if grep -Fq -- "$needle" "$temp_root/out"; then fail "$desc (unexpected output '$needle'; output: $(cat "$temp_root/out"))"; fi
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
    reviewed_at: "2026-10-13T10:30:00Z"
    constraints: []
EOF
}

write_approval_config() {
  mkdir -p "$1/.intent"
  cat > "$1/.intent/config.yaml" <<'EOF'
protocol_version: "2.0"
review:
  required: true
  authorized_reviewers:
    - "reviewer:maintainer-1"
EOF
}

change_digest_value() {
  printf 'sha256:%s\n' "$(sha256_file "$1/.intent/changes/CHG-0001/proposal.md.body")"
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

# The body digest matches and the verifier reports it.
repo=$temp_root/digest-pass
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
run_verifier --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo" || fail "digest success run failed: $(cat "$temp_root/out")"
grep -Fq 'digest matches' "$temp_root/out" || fail 'digest success message missing'
pass 'digest matches and is reported'

# A body edit after the digest was recorded fails.
repo=$temp_root/digest
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
printf 'extra line\n' >> "$repo/.intent/changes/CHG-0001/proposal.md"
expect_fail 'body edit fails digest mismatch' 'digest mismatch' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A front-matter-only edit keeps the digest valid.
repo=$temp_root/front-matter-edit
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^title: .*/title: "Renamed fixture change"/'
expect_pass 'front-matter edit keeps the digest valid' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# --print-digest prints the body digest.
repo=$temp_root/print-digest
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
printed=$(sh "$verifier" --change .intent/changes/CHG-0001 --root "$repo" --print-digest)
expected=sha256:$(sha256_file "$repo/.intent/changes/CHG-0001/proposal.md.body")
[ "$printed" = "$expected" ] || fail "print-digest mismatch: $printed != $expected"
pass '--print-digest prints the body digest'

# A leading byte order mark fails.
repo=$temp_root/bom
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
printf '\357\273\277' > "$temp_root/with-bom"
cat "$repo/.intent/changes/CHG-0001/proposal.md" >> "$temp_root/with-bom"
mv "$temp_root/with-bom" "$repo/.intent/changes/CHG-0001/proposal.md"
expect_fail 'leading BOM fails' 'byte order mark' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A file without front matter fails as a parse error.
repo=$temp_root/no-front-matter
new_fixture "$repo"
printf 'Draft proposal.\n' > "$repo/.intent/changes/CHG-0001/proposal.md"
expect_fail 'missing front matter fails' 'missing valid front matter' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A body starting with a horizontal rule is fine.
repo=$temp_root/body-rule
new_fixture "$repo"
make_change "$repo" '---
After a rule.'
expect_pass 'body starting with --- passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# CRLF front matter parses and the digest is unchanged.
repo=$temp_root/crlf
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
awk '{ printf "%s\r\n", $0 }' "$repo/.intent/changes/CHG-0001/proposal.md" > "$temp_root/crlf.md"
mv "$temp_root/crlf.md" "$repo/.intent/changes/CHG-0001/proposal.md"
expect_pass 'CRLF front matter parses with an unchanged digest' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Lifecycle states.
repo=$temp_root/unknown-state
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^status: "implementing"/status: "bogus"/'
expect_fail 'unknown status fails' 'status' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/withdrawn
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^status: "implementing"/status: "withdrawn"/'
expect_pass 'withdrawn status is accepted' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/complete
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^status: "implementing"/status: "complete"/'
expect_fail 'complete without conformance record fails' 'conformance.md' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"
printf '# Conformance record\n\nOutcome: verified.\n' > "$repo/.intent/changes/CHG-0001/conformance.md"
expect_pass 'complete with conformance record passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/missing-field
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
drop_line "$repo/.intent/changes/CHG-0001/proposal.md" '^request:'
expect_fail 'missing required field fails' 'request' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A changed path outside the declared scope fails.
repo=$temp_root/scope
new_fixture "$repo"
make_change "$repo" 'Change app behavior.

Test changes: tests/test_app.py updated.' "$declared_test_changes" '  paths:
    - "src/**"'
printf 'def test_existing():\n    assert app() == 2\n' > "$repo/tests/test_app.py"
printf 'def app():\n    return 2\n' > "$repo/src/app.py"
expect_fail 'path outside declared scope fails' 'tests/test_app.py' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# The scope check treats declared globs literally even when the verifier's
# working directory holds matching paths (the v1 pathname-expansion bug).
repo=$temp_root/scope-cwd
new_fixture "$repo"
mkdir -p "$repo/src/lib"
printf 'def deep():\n    return 1\n' > "$repo/src/lib/deep.py"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm deep
base_sha=$(git -C "$repo" rev-parse HEAD)
make_change "$repo" 'Nested change.' 'test_changes: []' '  paths:
    - "src/**"'
printf 'def deep():\n    return 2\n' > "$repo/src/lib/deep.py"
expect_pass_in 'declared glob stays literal with the CWD inside the repo' "$repo" --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A match-everything declaration passes and covers nested paths.
repo=$temp_root/scope-all
new_fixture "$repo"
mkdir -p "$repo/src/lib"
printf 'def deep():\n    return 1\n' > "$repo/src/lib/deep.py"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm deep
base_sha=$(git -C "$repo" rev-parse HEAD)
make_change "$repo" 'Nested change.' 'test_changes: []' '  paths:
    - "**/*"'
printf 'def deep():\n    return 2\n' > "$repo/src/lib/deep.py"
expect_pass 'match-everything declaration passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A changed path with spaces is matched and reported intact.
repo=$temp_root/scope-space
new_fixture "$repo"
make_change "$repo" 'Docs change.' 'test_changes: []' '  paths:
    - "docs/**"'
mkdir -p "$repo/docs"
printf 'notes\n' > "$repo/docs/my notes.md"
expect_pass 'in-scope path with a space passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/scope-space-fail
new_fixture "$repo"
make_change "$repo" 'Docs change.' 'test_changes: []' '  paths:
    - "docs/**"'
mkdir -p "$repo/other"
printf 'notes\n' > "$repo/other/my file.txt"
expect_fail 'out-of-scope path with a space is reported intact' 'other/my file.txt' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A declared glob that matched nothing warns.
repo=$temp_root/unused-glob
new_fixture "$repo"
make_change "$repo" 'Source change.' 'test_changes: []' '  paths:
    - "src/**"
    - "docs/**"'
printf 'def app():\n    return 2\n' > "$repo/src/app.py"
expect_pass_with_output 'unused declared glob warns' 'declared scope path matched no changed file: docs/**' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/unused-glob-config
new_fixture "$repo"
make_change "$repo" 'Source change.' 'test_changes: []' '  paths:
    - "src/**"
    - "docs/**"'
printf 'def app():\n    return 2\n' > "$repo/src/app.py"
mkdir -p "$repo/.intent"
printf 'protocol_version: "2.0"\nreview:\n  required: false\n  authorized_reviewers: []\npolicy:\n  warn_unused_paths: false\n' > "$repo/.intent/config.yaml"
expect_pass_without_output 'warn_unused_paths false suppresses the warning' 'WARN' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/unused-glob-quiet
new_fixture "$repo"
make_change "$repo" 'Source change.' 'test_changes: []' '  paths:
    - "src/**"
    - "docs/**"'
printf 'def app():\n    return 2\n' > "$repo/src/app.py"
expect_pass_without_output '--quiet suppresses the warning' 'WARN' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo" --quiet

# A protected path declared by a glob passes.
repo=$temp_root/protected-glob
new_fixture "$repo"
mkdir -p "$repo/tests/flows"
printf 'spec\n' > "$repo/tests/flows/login.e2e.js"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm flows
base_sha=$(git -C "$repo" rev-parse HEAD)
make_change "$repo" 'Retarget a spec.' 'test_changes:
  - path: "tests/**/*.e2e.js"
    kind: modified
    reason: "uniform retarget"'
printf 'updated spec\n' > "$repo/tests/flows/login.e2e.js"
expect_pass 'protected path declared by glob passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# An added skip marker passes when declared.
repo=$temp_root/skip-declared
new_fixture "$repo"
make_change "$repo" 'Skip a test deliberately.' 'test_changes:
  - path: "src/suite_inline.rs"
    kind: skipped
    reason: "temporarily ignored by decision"'
printf '#[test]\n#[ignore]\nfn existing() {}\n' > "$repo/src/suite_inline.rs"
expect_pass 'declared skip marker passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

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

# A proposal mention alone does not replace the test_changes entry.
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
printf 'protocol_version: "2.0"\nreview:\n  required: false\n  authorized_reviewers: []\npolicy:\n  protected_paths:\n    - "checks/**"\n' > "$repo/.intent/config.yaml"
printf 'changed check body\n' > "$repo/checks/sample.txt"
expect_fail 'config protected path fails' 'checks/sample.txt' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Approval evidence bound to the current proposal digest.
repo=$temp_root/approval-pass
new_fixture "$repo"
make_change "$repo" 'Approved change.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^review_required: false/review_required: true/'
write_review "$repo" "$(change_digest_value "$repo")" 'reviewer:maintainer-1' approved
expect_pass 'approval for the current digest passes' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/approval-missing
new_fixture "$repo"
make_change "$repo" 'Change requiring approval.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^review_required: false/review_required: true/'
expect_fail 'missing approval evidence fails' 'approval evidence' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/approval-stale
new_fixture "$repo"
make_change "$repo" 'Change requiring approval.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^review_required: false/review_required: true/'
zeros=$(awk 'BEGIN { for (i = 0; i < 64; i++) printf "0" }')
write_review "$repo" "sha256:$zeros" 'reviewer:maintainer-1' approved
expect_fail 'stale approval digest fails' 'approval evidence' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/approval-unauthorized
new_fixture "$repo"
make_change "$repo" 'Change requiring approval.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^review_required: false/review_required: true/'
write_review "$repo" "$(change_digest_value "$repo")" 'reviewer:stranger' approved
expect_fail 'unauthorized approval reviewer fails' 'authorized' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Auto-discovery of the only change record.
repo=$temp_root/autodiscover
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
expect_pass 'single change is auto-discovered' --base "$base_sha" --root "$repo"

# Pinned schema validation runs when the toolchain is available.
if python3 -c 'import yaml, jsonschema' >/dev/null 2>&1; then
  repo=$temp_root/schema-invalid
  new_fixture "$repo"
  make_change "$repo" 'Change app behavior.'
  mkdir -p "$repo/.intent/schemas/v2"
  cp "$repo_root"/schemas/v2/*.schema.json "$repo/.intent/schemas/v2/"
  flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^  revision: 1/  revision: 0/'
  expect_fail 'schema-invalid record fails' 'schema' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"
else
  printf 'skip - schema validation scenario (python3 with PyYAML and jsonschema unavailable)\n'
fi

printf 'All %s verifier scenarios passed.\n' "$passed"
