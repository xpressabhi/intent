# Conformance record

## Outcome

The export command accepts an explicit output-format option with `jsonl` as the new value and streams matching records one per line through the existing filtered iterator. The default JSON output is unchanged.

Change `CHG-0002` revision 1, body digest
`sha256:908dd88760c47f2cec8d760a5d4e157b40d8f4482c586008f7255f6109bbe51f`.

## Verification

| Check | Result |
| ----- | ------ |
| Focused export tests | Pass — empty, single-record, multi-record, and write-failure cases |
| Existing JSON output tests | Pass, unmodified |
| Bounded-memory spot check | A filtered multi-record export is consumable line by line |

## Test changes

`tests/export_test.py` — modified as declared: the existing test now also asserts the `jsonl` option; its default-output assertion is unchanged.

## Deviations and decisions

- None material. The format option is explicit rather than inferred from the extension, so scripted callers cannot change behavior accidentally.

## Approval constraints

Approved digest
`sha256:908dd88760c47f2cec8d760a5d4e157b40d8f4482c586008f7255f6109bbe51f`
by `reviewer:maintainer-1`. Constraints honored: current flags and default output behavior preserved; no runtime dependency added.
