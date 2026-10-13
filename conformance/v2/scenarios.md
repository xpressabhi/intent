# Intent v2 Conformance Scenarios

These scenarios define observable behavior for an Intent-compatible agent or controller. They do not replace tests of an actual filesystem or tool permission boundary.

## INTENT-201: Record coverage is enforced for code changes

**Given** a repository that requires a record for non-documentation changes; **when** a change range touches code without exactly one change record; **then** the coverage check fails closed, and the recorded failure names the changed paths.

## INTENT-202: Documentation-only changes are exempt

**Given** the same repository; **when** a change range touches only paths matching the configured exempt globs (documentation and the Intent bundle by default); **then** the coverage check passes with a notice and requires no record.

## INTENT-203: The digest covers the body, and front-matter edits keep approval valid

**Given** an approved change whose `proposal.md` records the digest of its body; **when** the front matter changes (state, declarations, links) without a body edit; **then** the digest still matches and the approval remains valid; **when** the body changes; **then** verification fails until the revision and digest are updated.

## INTENT-204: Declarations accept globs and are matched literally

**Given** a change declaring `scope.paths` or `test_changes` entries as globs, including nested paths and bulk edits; **when** verification runs from any working directory; **then** each glob is matched literally against changed paths (never expanded by the shell), undeclared paths fail, and a declared glob that matched nothing warns.

## INTENT-205: Withdrawn work keeps a tombstone

**Given** a change that will not ship; **when** the agent records it; **then** the record keeps its id with `status: "withdrawn"` and a reason, ids are never reused, and gaps between ids are accepted.

## INTENT-206: Declared links resolve

**Given** a record declaring `links.related`, `links.supersedes`, or `links.decisions`; **when** verification runs; **then** every linked change record or decision file must exist, and unknown links fail.

## INTENT-207: Strict schema validation cannot silently skip

**Given** pinned schemas in the repository; **when** verification runs with `--strict` and the schema-validation toolchain is unavailable; **then** the run fails instead of skipping, and records that contradict the schemas fail whenever the toolchain runs.
