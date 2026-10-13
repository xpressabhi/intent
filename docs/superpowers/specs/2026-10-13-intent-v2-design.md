# Intent v2 — Lean records and enforcement

**Date:** 2026-10-13
**Status:** Approved design, pending implementation
**Scope:** the Intent protocol bundle in this repository — protocol, schemas, verifier scripts, migration/installer, guidance and docs, CI template, tests.

## 1. Context and evidence

An audit of the first real adoption (selftest-lite, 2026-09-28 → 2026-10-13: 42 commits, 17 change records) found:

- **Under-tracking.** 22 of 42 commits had no record — 15 substantive fixes including two security fixes — because the shipped CI model ran only on pull requests, only verified when a record changed, and every commit went directly to `main` (zero merges).
- **Over-declaration.** Early records declared scope envelopes that matched nothing (CHG-0002 used 4 of 6 declared globs); `.intent/**` declarations are inert; blanket `src/**` made the scope check vacuous.
- **Triple bookkeeping.** `proposal.md` + `change.yaml` + `conformance.md` repeated the same facts by hand; drift appeared in practice (CHG-0009's test list went stale after a post-deploy fix; CHG-0017 declared 1 of 45 modified test files).
- **No decision memory.** CHG-0012 re-shipped the in-process read cache that CHG-0006/CHG-0007 had built, measured, and reverted three days earlier, with no cross-reference; `.intent/decisions/` is empty.
- **A real verifier defect.** Declared globs were pathname-expanded by unquoted shell loops, so `src/**` stopped matching when the verifier ran from a repository root containing matching files. selftest-lite patched its pinned copy and noted that `--upgrade` would reintroduce the bug. Upstream still has it.
- **Ambiguous conventions.** The schema allows `test_changes` kind `added` while the template says "pre-existing tests only"; proposal structure drifts from the template; lifecycle states are never used; ID gaps are unexplained (CHG-0006).
- **Inert checks.** Schema validation silently skipped whenever python3 + PyYAML + jsonschema were absent — observed on every run.

## 2. Goals and non-goals

**Goals**

- Every fact is recorded once; no hand-synced mirrors.
- Every non-doc change carries a record, enforced in CI (docs-only changes are exempt; design docs that precede a change are linked by that change's record).
- Declarations are precise, machine-checked, and support bulk/mechanical changes.
- Prior decisions are reachable; reversals and relations are explicit.
- No check can silently skip in strict mode; the verifier defect is fixed upstream with regression coverage.
- One-time migration preserves history, digests, and approval evidence.

**Non-goals (this iteration)**

- A CLI/controller (deferred; §11.1).
- A records index, dashboards, or filesystem-level enforcement.
- Dual-vintage reading (v2 tooling reads v2 records only).
- Multiple change records in one range.
- Any modification of selftest-lite (follow-up; §11.2).

## 3. Record format

### 3.1 Layout

```
.intent/changes/CHG-XXXX/
  proposal.md     # YAML front matter + the intent body (the digested proposal)
  conformance.md  # evidence record (unchanged role)
  review.yaml     # only when approval is required
```

`change.yaml` is deleted. `.intent/changes/TEMPLATE/` mirrors the new shapes (`proposal.md`, `conformance.md`, `review.yaml.tmpl`).

### 3.2 Front matter

Fields (all machine-consumed; nothing here duplicates the body):

| Field | Required | Notes |
|---|---|---|
| `protocol_version` | yes | const `"2.0"` |
| `id` | yes | `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` |
| `title` | yes | non-empty |
| `status` | yes | `draft`, `in_review`, `changes_requested`, `rejected`, `approved`, `implementing`, `conformance_review`, `complete`, `withdrawn` |
| `created_at` | yes | RFC 3339 |
| `request` | yes | one line: the requested observable outcome |
| `proposal.revision` | yes | integer ≥ 1 |
| `proposal.digest` | yes | `sha256:` + 64 hex |
| `scope.paths` | no | list of globs; when present, changed non-`.intent` paths must match |
| `test_changes` | no | list of `{path, kind, reason}`; `path` may be an exact path or a glob; `kind` ∈ `added`, `modified`, `deleted`, `skipped` (documentation) |
| `links` | no | map of lists: `related`, `supersedes` (CHG ids), `decisions` (DEC ids) |
| `review_required` | yes | boolean |

Example:

```yaml
---
protocol_version: "2.0"
id: "CHG-0018"
title: "Example change"
status: "complete"
created_at: "2026-10-13T10:00:00Z"
request: "One line stating the requested observable outcome."
proposal:
  revision: 1
  digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
scope:
  paths:
    - "src/**"
test_changes:
  - path: "src/**/*.test.js"
    kind: modified
    reason: "Mechanical import rewrite; no assertion changed."
links:
  related: []
  supersedes: []
  decisions: []
review_required: false
---
```

**Parse subset (normative).** The file starts with `---` on line 1; the front matter ends at the first following line that is exactly `---`; the body is everything after. Front matter allows two-space indentation, tabs are forbidden, scalars are bare or double-quoted, `proposal` is the only nested map other than `scope` (`paths` list) and `links` (lists), and `test_changes` is a list of maps with the three keys. Multiline scalars, anchors, tags, flow collections, and comments inside front matter are rejected with a clear error. The JSON schema under `schemas/v2/` is the formal contract; the POSIX-sh parser implements the same subset.

### 3.3 Body

Free-form Markdown; the recommended sections are Outcome (request + observable result), Scope (Included/Excluded), Preserved behavior, Test changes, Decisions and constraints, Verification plan. The body is the proposal for approval and digest purposes. Structure is not machine-enforced.

### 3.4 Digest

- `body` = the bytes after the front matter, exactly.
- `digest` = SHA-256 of the body with all CR bytes removed (`tr -d '\r'`, byte-for-byte the v1 verifier's normalization, so migrated digests are preserved); the file must not begin with a byte order mark.
- Any body edit requires a `proposal.revision` increment and a new digest.
- Front-matter-only edits (status, `scope.paths`, `test_changes`, `links`) never change the digest and never invalidate approvals.
- Migrated v1 records keep a byte-identical body and therefore an unchanged digest.

### 3.5 Status and IDs

- `withdrawn` is the tombstone for work that will not ship (for example, reverted work). The record stays with one line of why.
- IDs are allocated sequentially and never reused; gaps are permitted and expected (CHG-0006's pattern is now representable).

## 4. Verifier v2 — `verify-change.sh`

Same interface as v1 (`--change`, `--base`, `--head`, `--command`, `--baseline`, `--protected`, `--root`, `--print-digest`) plus:

- `--strict` — a skipped schema validation is a failure.
- `--quiet` — suppress warnings.

Checks, in order:

1. `proposal.md` exists and parses; structural errors are explicit. `status: complete` requires `conformance.md`.
2. `protocol_version` is `2.0`; required fields, types, enums, and patterns pass (independent of python).
3. Body digest matches `proposal.digest`; `revision` ≥ 1; no leading BOM.
4. `links` targets resolve: `CHG-*` directories exist; `DEC-*.md` files exist.
5. Approval, when required by config or `review_required`: an approved review entry for the current digest from an authorized reviewer exists for statuses `approved`, `implementing`, `conformance_review`, `complete`.
6. Scope: every changed path outside `.intent/` matches a declared `scope.paths` glob when declared. Matching is literal-safe (`set -f`, quoted expansions — the fix). A declared glob that matches no changed file prints `verify-change: WARN: ...` unless `policy.warn_unused_paths: false`.
7. Protected paths: net modified/deleted paths matching the protected patterns must match a `test_changes` entry (exact or glob). Added files are exempt. The v1 requirement that the path also appear verbatim in the proposal text is removed — declarations and prose now live in the same file.
8. Test weakening: a diff that removes a test definition or adds a skip marker requires a matching `test_changes` entry.
9. Schema validation against the pinned `schemas/v2/`: when the toolchain is unavailable it prints a warning; with `--strict` that is a failure.
10. Verification command and baseline behavior unchanged.

Warnings print as `verify-change: WARN: ...` and never fail the run.

## 5. Coverage gate and CI

### 5.1 `verify-records.sh`

`verify-records.sh --base REF [--head REF] [--root DIR]`

- Changed set = `git diff --name-status base..head` (or the working tree).
- If every changed path matches `policy.record_exempt_paths` (default: `docs/**`, `**/*.md`, `.intent/**`; configurable) → pass with the notice `verify-records: docs-only change; no record required`.
- Otherwise exactly one record directory must be added or modified in the range (a `.intent/changes/CHG-*/` containing `proposal.md`):
  - 0 → fail `no Intent record for this change`, unless a commit in the range contains an `Intent-Skip: <reason>` trailer (then pass with a notice that names the reason);
  - 1 → pass and print `verify-records: record CHG-XXXX` (CI forwards the directory);
  - ≥2 → fail `one record per change`.
- Rationale for `.intent/**` exemption: record maintenance and bundle policy edits must not require their own record; changes that accompany a record are covered by that record's declared scope.

### 5.2 CI template

`install/templates/.github/workflows/intent-verify.yml`, installed by `--ci`:

- Triggers: `pull_request` (all branches) and `push` to `main`.
- Base revision: `origin/${{ github.base_ref }}` for PRs; `github.event.before` for pushes, falling back to `HEAD^` when `before` is empty or all zeros.
- Steps: install `pyyaml jsonschema`; run `verify-records.sh --base "$base"`; when it prints a record, run `verify-change.sh --change "$dir" --base "$base" --strict`.
- The template is generic; adopters may adjust the branch names.

## 6. Migration — `migrate-v1.sh`

`sh scripts/migrate-v1.sh --target DIR [--dry-run] [--ci]`

**Preflight:** the target is a Git repository with a v1 install (`.intent/config.yaml`, `protocol/v1.md`), a clean working tree, and every change directory containing `proposal.md`. Fail with a list of offenders otherwise; never write on failure.

**Per change directory:**

- Read `change.yaml` and write front matter onto `proposal.md`: `protocol_version: "2.0"`, `id`, `title`, `status`, `created_at`, `request`, `proposal.revision`, `proposal.digest`, `scope.paths`, `test_changes`, `review_required`; drop `proposal.path`; initialize `links` empty.
- The body bytes are untouched. The migrator recomputes the body digest and asserts it equals the v1 `proposal.digest`; a mismatch fails loudly.
- v1 mirror fields (`scope.included`, `scope.excluded`, `preserved`, `decisions`): when their normalized text already appears in the body, they are dropped; otherwise they are written verbatim to `CHG-XXXX/_v1-notes.md` and every such file is listed in the report. The body is never edited, so digests and approval evidence stay valid.
- `conformance.md` and `review.yaml` are untouched.

**Bundle:**

- Removes `.intent/protocol/v1.md` and `.intent/schemas/v1/`; installs `protocol/v2.md`, `schemas/v2/`, the v2 scripts, and the v2 guidance/templates; updates `config.yaml` to `protocol_version: "2.0"` while preserving `policy` and `review` values; re-verifies the `AGENTS.md` managed block.
- Leaves `PROJECT.md`, `decisions/` (except the README), and all record evidence untouched.
- States clearly that managed files modified locally (for example, a patched verifier) are deliberately replaced — the fixes are in v2 now.
- Never stages or commits; `--dry-run` prints the complete plan.

## 7. Installer v2

- Fresh installs ship v2 (`protocol/v2.md`, `schemas/v2/`, v2 scripts, guidance, templates). The v1 files remain in this repository for history and for adopters pinned to v1, but are no longer installed.
- New flag `--ci`: installs the CI template at `.github/workflows/intent-verify.yml` when absent; an identical file is kept; a differing file is a preflight failure (resolve manually). Works with `--dry-run`.
- All other behavior (managed `AGENTS.md` block, config handling, default protected paths, `--upgrade` for v2→v2 pin moves) is unchanged.

## 8. Decisions memory

- `.intent/decisions/DEC-XXXX.md`: front matter (`id`, `title`, `status` ∈ `active`, `superseded`, `reverted`; `date`; optional `supersedes`) + body sections Context / Decision / Consequences.
- Records link decisions via `links.decisions`; the verifier resolves every link.
- Promotion rule (guidance): promote a decision when it constrains future changes or when work is reverted/superseded. First candidate from the evidence: "No in-process read caches for API reads; measured and reverted; region co-location was the fix" (CHG-0006/CHG-0007).

## 9. Guidance and docs

- `AGENT_GUIDE.md` (v2): the decided policy (all non-doc changes get a record; short records are encouraged; docs-only exempt; design docs linked by the record); searching `.intent/decisions/` and prior records before proposing (with a grep recipe); extend-vs-new-record rules (a post-completion fix that stays within the recorded intent updates that record — body revision or conformance append; anything else opens a new record); a bulk/mechanical declaration example (`src/**/*.test.js` with a reason); ID and `withdrawn` policy; declaration hygiene (narrow paths; do not declare `.intent/**`).
- `protocol/v2.md`: the v1 text with the deltas — single-file record, body digest, `withdrawn`, coverage expectations, glob declarations, links.
- `schemas/v2/change.schema.json` (the front matter object), `config.schema.json` (adds `record_exempt_paths`, `warn_unused_paths`), `review.schema.json` (v2 copy).
- `conformance/v2/scenarios.md`: updated observable scenarios (coverage gate; body digest vs front-matter edits; glob declarations; withdrawn tombstone; link resolution; docs-only exemption).
- `README.md`, `docs/install-prompt.md`, and `docs/index.html` updated for v2, migration, and CI.
- `examples/v2/` added with small-fix, feature-change, and architectural-change records matching `examples/v1/`'s spirit.

## 10. Tests and repository CI

- `tests/verify-change.sh` — ported and extended:
  1. body digest match/mismatch; front-matter-only edits leave the digest valid.
  2. leading BOM rejected.
  3. missing/invalid front matter fails; unknown status fails; `withdrawn` accepted.
  4. `complete` without `conformance.md` fails.
  5. approvals: current digest passes; missing, stale, unauthorized fail; front-matter edit does not break a valid approval.
  6. scope: in-scope pass **with the verifier's CWD inside a fixture that contains `src/`** (the glob regression); out-of-scope fail; nested paths under `src/**` match.
  7. unused declared glob prints a warning; `warn_unused_paths: false` suppresses it.
  8. protected: exact declaration passes; undeclared fails; glob declaration passes.
  9. skip marker added without declaration fails; with declaration passes; added test file without declaration passes.
  10. config `protected_paths` honored.
  11. verification command pass/fail; baseline.
  12. schema validation: absent toolchain warns; `--strict` fails; invalid record fails when the toolchain exists.
  13. links: unknown CHG/DEC target fails; known passes.
  14. auto-discovery of a single record; `--print-digest` prints the body digest.
- `tests/verify-records.sh` — new: code change without record fails; with record passes and prints it; docs-only passes; `Intent-Skip:` trailer passes with a notice; two records fail; configured exempt globs respected.
- `tests/migrate.sh` — new: a v1 fixture migrates to v2 records that pass the v2 verifier; digests unchanged; a `review.yaml` approval stays valid; unmatched v1 text lands in `_v1-notes.md`; `config.yaml` policy preserved and version bumped; managed files replaced; `PROJECT.md`/`decisions/` untouched; dirty tree refused; missing `proposal.md` reported.
- `tests/install.sh` — extended: v2 fresh install; `--ci` writes when absent, keeps identical, fails on differing; `--dry-run` reports everything.
- `.github/workflows/tests.yml` in this repository: runs every `tests/*.sh` on push and PR (the repository currently has no CI).

## 11. Follow-ups (not this change)

1. **CLI (approach C)** — `intent new|verify|related|migrate|status`; reconsider after v2 has real usage.
2. **Migrate selftest-lite** with `migrate-v1.sh`; then repair its CHG-0017 record locally (declare `src/**/*.test.js` via a glob, or revert the formatter churn) so it passes verification.
3. **Consider dogfooding**: adopt Intent in this repository.
4. **Records index** if the changes directory grows beyond what `ls` and grep handle (YAGNI now).

## 12. Acceptance criteria

- All tests above pass; a fresh v2 install and a `--dry-run` migration run clean on fixtures.
- Glob regression: the positive in-scope scenario passes with the verifier's CWD inside a matching fixture, and fails against the current v1 verifier.
- A code-only range with no record fails `verify-records.sh`; with a record, or with an `Intent-Skip:` trailer, it passes; a docs-only range passes.
- A CHG-0017-style bulk test rewrite passes with a single glob declaration.
- Fixture migration leaves digests unchanged, approvals valid, and no content lost (unmatched text archived and reported).
- `--strict` makes schema validation impossible to skip silently.
- A dry-run migration walkthrough of selftest-lite's 17 records reports no digest mismatches and no unarchived content loss.
