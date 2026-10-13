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
# record as proposal.md.body so tests can recompute its digest. An optional
# fifth argument (or $LINKS_YAML) adds a `links:` block under the front matter.
make_change() {
  dir=$1
  body_text=$2
  test_yaml=${3-${TEST_YAML-'test_changes: []'}}
  scope_yaml=${4-${SCOPE_YAML-'  paths: []'}}
  links_yaml=${5-${LINKS_YAML-}}
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
    if [ -n "$links_yaml" ]; then
      printf 'links:\n%s\n' "$links_yaml"
    fi
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
expect_pass_without_output 'warn_unused_paths false suppresses the warning' 'declared scope path matched no changed file' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

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

# A front-matter-only edit after approval keeps the approval valid.
repo=$temp_root/approval-frontmatter-edit
new_fixture "$repo"
make_change "$repo" 'Approved change.'
write_approval_config "$repo"
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^review_required: false/review_required: true/'
write_review "$repo" "$(change_digest_value "$repo")" 'reviewer:maintainer-1' approved
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^title: .*/title: "Retitled after approval"/'
expect_pass 'front-matter edit keeps approval valid' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Declared links resolve against records and decisions that exist.
repo=$temp_root/links
new_fixture "$repo"
make_change "$repo" 'Linked change.' 'test_changes: []' '  paths: []' '  related:
    - "CHG-0002"'
mkdir -p "$repo/.intent/changes/CHG-0002"
printf 'stub record\n' > "$repo/.intent/changes/CHG-0002/proposal.md"
expect_pass 'known change link resolves' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/link-unknown
new_fixture "$repo"
make_change "$repo" 'Linked change.' 'test_changes: []' '  paths: []' '  related:
    - "CHG-0009"'
expect_fail 'unknown change link fails' 'unknown change link' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/decision-link
new_fixture "$repo"
make_change "$repo" 'Linked decision.' 'test_changes: []' '  paths: []' '  decisions:
    - "DEC-0001"'
mkdir -p "$repo/.intent/decisions"
printf '# stub decision\n' > "$repo/.intent/decisions/DEC-0001.md"
expect_pass 'known decision link resolves' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/decision-unknown
new_fixture "$repo"
make_change "$repo" 'Linked decision.' 'test_changes: []' '  paths: []' '  decisions:
    - "DEC-0009"'
expect_fail 'unknown decision link fails' 'unknown decision link' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Links of different kinds resolve independently: a valid decision id must not
# be read as a change link (sibling list keys stay scoped to their own items).
repo=$temp_root/links-kinds
new_fixture "$repo"
make_change "$repo" 'Linked kinds.' 'test_changes: []' '  paths: []' '  related:
    - "CHG-0002"
  decisions:
    - "DEC-0001"'
mkdir -p "$repo/.intent/changes/CHG-0002" "$repo/.intent/decisions"
printf 'stub record\n' > "$repo/.intent/changes/CHG-0002/proposal.md"
printf '# stub decision\n' > "$repo/.intent/decisions/DEC-0001.md"
expect_pass 'links of different kinds resolve independently' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Globs cover top-level paths: `**/*` matches a root file, and the default
# protected patterns protect root-level test files.
repo=$temp_root/scope-all-toplevel
new_fixture "$repo"
printf 'x = 1\n' > "$repo/setup.py"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm toplevel
base_sha=$(git -C "$repo" rev-parse HEAD)
make_change "$repo" 'Top-level change.' 'test_changes: []' '  paths:
    - "**/*"'
printf 'x = 2\n' > "$repo/setup.py"
expect_pass '**/* matches a top-level file' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/protected-root-test
new_fixture "$repo"
printf 'test("x", () => {});\n' > "$repo/app.test.js"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm roottest
base_sha=$(git -C "$repo" rev-parse HEAD)
make_change "$repo" 'Change a root test.' 'test_changes: []'
printf 'test("x", () => { expect(1).toBe(1); });\n' > "$repo/app.test.js"
expect_fail 'root-level test file is protected' 'app.test.js' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Declared patterns containing spaces are matched without word splitting.
repo=$temp_root/scope-space-pattern
new_fixture "$repo"
mkdir -p "$repo/dir"
printf 'one\n' > "$repo/dir/my file.txt"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm spaced
base_sha=$(git -C "$repo" rev-parse HEAD)
make_change "$repo" 'Space in a declared path.' 'test_changes: []' '  paths:
    - "dir/my file.txt"'
printf 'two\n' > "$repo/dir/my file.txt"
expect_pass 'declared path with a space matches' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/protected-space
new_fixture "$repo"
mkdir -p "$repo/dir"
printf 'one\n' > "$repo/dir/my file.txt"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm spaced
base_sha=$(git -C "$repo" rev-parse HEAD)
make_change "$repo" 'Protected space.' 'test_changes: []'
printf 'two\n' > "$repo/dir/my file.txt"
expect_fail 'protected pattern with a space is honored' 'dir/my file.txt' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo" --protected 'dir/my file.txt'

# The front-matter subset is enforced: unsupported syntax is a hard error.
repo=$temp_root/frontmatter-flow
new_fixture "$repo"
make_change "$repo" 'Unsupported syntax.' 'test_changes: []'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's|^scope:$|scope: {paths: ["src/**"]}|; s/^  paths: \[\]$//'
printf 'def test_existing():\n    assert app() == 2\n' > "$repo/tests/test_app.py"
expect_fail 'flow-style scope is rejected' 'unsupported syntax' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/frontmatter-anchor
new_fixture "$repo"
make_change "$repo" 'Anchors rejected.' 'test_changes: []'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^scope:$/scope: \&anchor/'
expect_fail 'anchors in front matter are rejected' 'unsupported syntax' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/frontmatter-tab
new_fixture "$repo"
make_change "$repo" 'Tabs rejected.' 'test_changes: []'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" "s/^request:/$(printf '\t')request:/"
expect_fail 'tab-indented front matter is rejected' 'unsupported syntax' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/frontmatter-comment
new_fixture "$repo"
make_change "$repo" 'Comments rejected.' 'test_changes: []'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^request:.*/# request goes here/'
expect_fail 'comments in front matter are rejected' 'unsupported syntax' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# A trailing space after a section key must not disable its checks.
repo=$temp_root/frontmatter-trailing-space
new_fixture "$repo"
make_change "$repo" 'Trailing space.' 'test_changes: []' '  paths:
    - "src/**"'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^scope:$/scope: /'
printf 'def test_existing():\n    assert app() == 2\n' > "$repo/tests/test_app.py"
expect_fail 'trailing space after scope stays enforced' 'path outside declared scope' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Structural checks hold without the schema toolchain.
repo=$temp_root/revision-zero
new_fixture "$repo"
make_change "$repo" 'Bad revision.' 'test_changes: []'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^  revision: 1/  revision: 0/'
expect_fail 'revision zero fails without the toolchain' 'revision must be a positive integer' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/bad-id
new_fixture "$repo"
make_change "$repo" 'Bad id.' 'test_changes: []'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^id: .*/id: "bad id with spaces"/'
expect_fail 'invalid change id fails' 'change id must match' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/empty-title
new_fixture "$repo"
make_change "$repo" 'Empty title.' 'test_changes: []'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^title: .*/title: ""/'
expect_fail 'empty title fails' 'title must not be empty' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/bad-created
new_fixture "$repo"
make_change "$repo" 'Bad timestamp.' 'test_changes: []'
flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^created_at: .*/created_at: "yesterday"/'
expect_fail 'invalid created_at fails' 'created_at must be an RFC 3339' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

repo=$temp_root/bad-kind
new_fixture "$repo"
make_change "$repo" 'Bad kind.' 'test_changes:
  - path: "tests/x.test.js"
    kind: bogus
    reason: "x"'
expect_fail 'unknown test_changes kind fails' 'kind is not one of' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"

# Every shipped example's recorded digest matches its body.
for change_dir in "$repo_root"/examples/v2/*/.intent/changes/CHG-*; do
  [ -f "$change_dir/proposal.md" ] || continue
  rel=${change_dir#"$repo_root"/}
  printed=$(sh "$verifier" --root "$repo_root" --change "$rel" --print-digest)
  recorded=$(sed -n 's/^  digest: "\(sha256:.*\)"$/\1/p' "$change_dir/proposal.md")
  if [ "$printed" != "$recorded" ]; then fail "example digest mismatch: $rel records $recorded but its body is $printed"; fi
done
pass 'example record digests match their bodies'

# Schema validation: present toolchain validates; absent toolchain warns, and
# --strict turns that skip into a failure.
repo=$temp_root/strict
new_fixture "$repo"
make_change "$repo" 'Change app behavior.'
mkdir -p "$repo/.intent/schemas/v2"
cp "$repo_root"/schemas/v2/*.schema.json "$repo/.intent/schemas/v2/"
if python3 -c 'import yaml, jsonschema' >/dev/null 2>&1; then
  expect_pass '--strict passes when schema validation runs' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo" --strict
else
  expect_pass_with_output 'schema validation warns without the toolchain' 'schema validation skipped' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"
  expect_fail '--strict fails when schema validation cannot run' 'schema' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo" --strict
fi

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

  repo=$temp_root/yaml-error
  new_fixture "$repo"
  make_change "$repo" 'Malformed YAML.'
  mkdir -p "$repo/.intent/schemas/v2"
  cp "$repo_root"/schemas/v2/*.schema.json "$repo/.intent/schemas/v2/"
  flip_change "$repo/.intent/changes/CHG-0001/proposal.md" 's/^request: ".*"$/request: "unterminated/'
  expect_fail 'malformed YAML fails as a schema error' 'schema' --change .intent/changes/CHG-0001 --base "$base_sha" --root "$repo"
else
  printf 'skip - schema validation scenario (python3 with PyYAML and jsonschema unavailable)\n'
fi

printf 'All %s verifier scenarios passed.\n' "$passed"
