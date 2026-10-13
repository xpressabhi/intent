# Conformance record

## Outcome

The export command accepts an explicit output-format option with `jsonl` as the new value and streams matching records one per line through the existing filtered iterator. The default JSON output is unchanged.

Change `CHG-0002` revision 1, body digest
`sha256:2b5728f24bd06d6ead47d7d01c783d1a432a69ed1bc788c2e0db88419774627b`.

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
`sha256:2b5728f24bd06d6ead47d7d01c783d1a432a69ed1bc788c2e0db88419774627b`
by `reviewer:maintainer-1`. Constraints honored: current flags and default output behavior preserved; no runtime dependency added.
