# Intent workflow

Follow [protocol/v2.md](protocol/v2.md). Use the lightest workflow that can deliver and verify the requested outcome: understand context, make and record material decisions, implement, verify, and include operations only when requested.

Proceed autonomously when the outcome is clear and within repository policy. Use repository conventions for routine choices; record material assumptions. Ask a human only when unresolved information would materially change the outcome or when repository policy reserves an action for human authority. Keep the question specific and continue independent safe work.

Every change that alters code, tests, build, configuration, dependencies, or data carries a record under `.intent/changes/`: a `proposal.md` (front matter plus a short intent body) and, before completion, a `conformance.md`. Documentation-only changes are exempt. A design document written before a change is linked from that record's body (a "Design:" line); it does not need its own record.

## Before proposing

Search the existing records for decisions that touch the same paths or purpose — a reversal, a measured rejection, or a constraint you would otherwise re-open:

    grep -ril "<area or keyword>" .intent/decisions .intent/changes | head

Link what you find through `links.related`, `links.supersedes`, or `links.decisions` in the front matter. Every linked id must resolve.

## The record

- Front matter (machine-read): `protocol_version`, `id`, `title`, `status`, `created_at`, `request`, `proposal.revision`, `proposal.digest`, and optional `scope.paths`, `test_changes`, `links`, plus `review_required`.
- Body: Outcome, Scope, Preserved behavior, Test changes, Decisions, Verification plan. Keep routine changes short. The digest covers the body only, so front-matter edits (status, declarations, links) never invalidate an approval.
- `scope.paths` is an optional permission envelope of globs. Declare narrow paths instead of `src/**`-style blankets, and do not declare `.intent/**`; a declared glob that matches nothing produces a warning.
- `test_changes` lists every pre-existing test the change modifies, deletes, or skips, with a reason. An entry may be a glob when the edit is uniform, for example a mechanical rewrite: `path: "src/**/*.test.js"`.
- Preserve existing behavior: never modify, skip, or delete a pre-existing test to make it pass; record a regression instead.
- Before marking `complete`, write `conformance.md` with the outcome, deviations, decisions, and verification results.
- Ids are sequential and never reused; gaps are fine. A change that will not ship keeps its record with `status: "withdrawn"` and one line of why.

## After completion

A fix found after completion that stays within the recorded intent updates the same record: a `conformance.md` append, or — when the intent text itself changes — a body edit with `proposal.revision` incremented and the digest recomputed. Anything outside the recorded intent opens a new record.

## Complete

The change record states the requested outcome, scope, material decisions, and relevant verification. Verify the changed behavior with relevant repository checks and record actual outcomes.

The coverage check (`scripts/verify-records.sh`) fails a change range that touches non-exempt paths without exactly one record; `Intent-Skip: <reason>` in a commit message is the auditable escape. The verifier (`scripts/verify-change.sh`) checks declarations, protected paths, and the body digest; use `--strict` where schema validation must not be skipped.

The installer supplies guidance and records, not a filesystem security boundary. Technical enforcement requires a controller to mediate tool access.

For a repository-wide approval gate, set `review.required: true` and list authorized reviewers in `.intent/config.yaml`. Otherwise, keep the default autonomous flow.
