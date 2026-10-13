---
protocol_version: "2.0"
id: "CHG-0000"
title: "TODO: title makes the intended result identifiable"
status: "draft"
created_at: "TODO: RFC 3339 timestamp"
request: "TODO: requested observable result"
proposal:
  revision: 1
  digest: "sha256:TODO"
scope:
  paths: []
test_changes: []
links:
  related: []
  supersedes: []
  decisions: []
review_required: false
---

# Change intent

> Keep routine changes short. Add detail only when complexity, risk, ambiguity, or repository policy needs it. The digest covers everything below the front matter: after any body edit, run `sh .intent/scripts/verify-change.sh --change <dir> --print-digest`, increment `proposal.revision`, and paste the printed digest into `proposal.digest`.

## Outcome

TODO: The requested result, distinguished from the current behavior.

## Scope

### Included

- TODO: Observable outcome included in the change.

### Excluded

- TODO: Outcome explicitly outside the change's scope.

## Preserved behavior

TODO: State that existing behavior and pre-existing tests remain unchanged, or list each intended exception. Use "None" when there are no exceptions.

## Test changes

TODO: List every pre-existing test modified, deleted, or skipped with its reason, or state "None." New tests are additions.

## Decisions and constraints

TODO: Record only material decisions, assumptions, risks, and repository constraints. Use "None" when there are none.

## Verification

TODO: Name relevant checks and expected results; scale detail to the change.
