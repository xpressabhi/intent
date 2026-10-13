---
protocol_version: "2.0"
id: "CHG-0001"
title: "Correct empty-input error message"
status: "in_review"
created_at: "2026-09-28T10:00:00Z"
request: "Report a clear validation error when the command receives an empty input file."
proposal:
  revision: 1
  digest: "sha256:4bebcdcfbe5a2b65db1a32692327f1dbd668491fd08609d1684890c165ed6368"
scope:
  paths: []
test_changes: []
links:
  related: []
  supersedes: []
  decisions: []
review_required: true
---

# Correct empty-input error message

## Request

Return a clear validation error when the command receives an empty input file.

## Context

The command currently reports a generic processing failure. The input parser already validates file contents before processing.

## Scope

Included: report the existing validation failure clearly and cover it with a focused test.

Excluded: change parser behavior, add dependencies, or alter command-line options.

## Preserved behavior

Parser behavior, command-line options, and existing tests remain unchanged.

## Test changes

None. The change adds focused coverage for the empty-input case.

## Proposed design

Use the parser's existing empty-input validation result and render its message through the current command error path.

## Implementation outline

1. Confirm the current parser error and command error path.
2. Add the focused message assertion.
3. Run the relevant validation tests.

## Risks and verification

The message could become inconsistent with other validation errors. Compare it with current command wording and verify the empty-input case.
