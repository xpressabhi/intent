# Stream filtered records as JSON Lines

## Request

Add a command that exports records matching the existing query filters as JSON Lines.

## Context

The repository already supports filtering and JSON responses, but large exports are currently assembled in memory. Consumers need a portable format that can be processed incrementally.

## Scope

Included: a JSON Lines output mode, streaming through the existing query path, and focused coverage for empty, single-record, and multi-record results.

Excluded: scheduled exports, cloud storage, new query syntax, and changes to the existing JSON response format.

## Preserved behavior

Existing JSON output, default behavior, and all other pre-existing tests remain unchanged.

## Test changes

tests/export_test.py — modified: the existing export test now also asserts the `jsonl` option while its default-output assertion stays unchanged.

## Proposed design

Add an explicit output-format option with `jsonl` as the new value. Reuse the existing filtered iterator and serialize one record per line. Keep the current JSON mode and its default unchanged. Report serialization and output errors through the existing command error path.

## Alternatives considered

- **Build a complete JSON array:** simple for consumers but retains the current memory growth problem.
- **Add a separate export service:** supports future destinations but adds an unnecessary service boundary for a local command.
- **Stream JSON Lines from the existing iterator:** selected because it supports bounded memory use and fits the existing command architecture.

## Constraints and risks

- Preserve current flags and default output behavior.
- Do not add a runtime dependency.
- A write failure may leave a partial output; return a non-zero result and describe this behavior.

## Implementation outline

1. Trace the query iterator and output abstraction.
2. Add the format option and streaming serializer.
3. Cover empty, single-record, multi-record, and write-failure behavior.
4. Compare memory behavior with the current full-response path.

## Verification

Run focused unit and command-level checks, then verify a filtered multi-record export can be consumed line by line and the existing JSON output remains unchanged.
