---
protocol_version: "2.0"
id: "CHG-0003"
title: "Move audit history to an append-only event stream"
status: "in_review"
created_at: "2026-09-28T11:00:00Z"
request: "Persist durable audit history for account-setting changes using the repository's existing event stream."
proposal:
  revision: 2
  digest: "sha256:0573b6aea636c2ebeb1f0260ece47fd1f9556c29dd9db554ee93f02d7a56a90d"
scope:
  paths: []
test_changes: []
links:
  related: []
  supersedes: []
  decisions: []
review_required: true
---

# Move audit history to an append-only event stream

## Request

Persist durable audit history for changes to account settings. Revision 1 proposed a separate relational audit table.

## Context and material discovery

Revision 1 proposed a separate relational audit table. During implementation investigation, the team found that this repository already has an append-only event stream that serializes account-setting writes. A second store would create two sources of truth and require cross-store consistency handling.

This changes the storage boundary and write path, so the approval for revision 1 no longer applies.

## Scope

Included: record account-setting changes in the existing event stream, add a versioned event representation, and provide a backward-compatible history read path.

Excluded: add a new storage service, change the current settings API, or rewrite unrelated event types.

## Proposed design

Extend the existing event stream with a versioned account-setting event. Derive history reads from that stream and retain the current settings projection as the source of truth. Define handling for older event versions before implementation begins.

## Alternatives considered

- **Keep the separate audit table:** rejected because it duplicates the serialized write path and creates consistency risks.
- **Use the existing event stream:** selected because it preserves one write authority and supports ordered history.

## Constraints and risks

- Preserve current settings API behavior.
- Define a migration or compatibility path for existing records.
- Do not add a separate persistence service.
- Event-version mistakes could make historical records unreadable.

## Implementation outline

1. Document current event ordering and existing record formats.
2. Specify the versioned event and compatibility behavior.
3. Add event writing and history reading.
4. Verify ordering, old-record compatibility, and failure handling.

## Verification

Review migration behavior with representative old and new events; verify ordered history, backward-compatible settings reads, and handling of unknown event versions.

## Revision history

- Revision 1 (superseded): store audit history in a separate relational audit table — see `proposal-history/revision-1.md`. The approval for revision 1 no longer applies to this revision.
