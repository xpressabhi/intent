# Intent

**Clear intent moves. Humans resolve what only humans can decide.**

Intent is a lightweight, agent-independent workflow for turning repository context and a requested outcome into a verified change. Agents handle clear in-scope decisions; people are asked only when ambiguity materially affects the outcome or repository policy reserves a decision for them.

See the [visual overview](docs/index.html) for diagrams of the lifecycle, digest binding, and verifier.

## The rule

The agent adapts the depth of its work to the change: understand, decide, implement, and verify; include release and operations only when requested. It records material decisions, continues safe independent work, and pauses only for a consequential human decision or an explicit repository approval boundary. Verification and traceability remain part of every change.

## The record

A v2 change record is a single `proposal.md`: YAML front matter carries the machine-readable declarations — state, `scope.paths`, `test_changes`, links, and the body digest — while the body carries the intent. The digest covers the body only, so declaration, state, and link edits never invalidate an approval; `conformance.md` records the outcome and evidence, and `review.yaml` appears only when approval is required. Every change that alters code, tests, build, configuration, dependencies, or data carries a record; documentation-only changes are exempt.

## Ownership

The Intent project defines the protocol, schemas, reference tooling, and adapters. Each target repository owns its decisions, architecture context, and change records under `.intent/`. Project knowledge stays with the codebase, and any capable agent can participate without defining the protocol itself.

## Protocol and schemas

- [Intent Protocol v2](protocol/v2.md) — adaptive lifecycle, human decision boundaries, and conformance evidence.
- [Reference change verifier](scripts/verify-change.sh) — checks a change's declarations, protected paths, links, and body digest, then runs the repository checks.
- [Coverage gate](scripts/verify-records.sh) — fails a change range that needs a record and has none.
- [Migration from v1](scripts/migrate-v1.sh) — moves existing records to the v2 shape with digests preserved.
- [Configuration schema](schemas/v2/config.schema.json)
- [Change record schema](schemas/v2/change.schema.json)
- [Review evidence schema](schemas/v2/review.schema.json)
- [Conformance scenarios](conformance/v2/scenarios.md)
- Protocol 1.0 stays readable for pinned adopters: [protocol/v1.md](protocol/v1.md), [schemas/v1/](schemas/v1/).

## Install in another repository

Intent is language- and build-system-independent. From a checkout of this repository, install its pinned v2 guidance bundle into any Git repository on macOS or Linux:

```sh
sh /path/to/intent/scripts/install.sh --target /path/to/your/repository
```

Installation is successful when the target is a Git repository and `.intent/` contains the version-pinned v2 bundle. Without `--target`, the target is the Git root of the current directory. The installer imports unique owners from the first available `.github/CODEOWNERS`, `CODEOWNERS`, or `docs/CODEOWNERS`; `--reviewer ID` adds explicit owners. If no owners are found, installation continues with a TODO in `.intent/config.yaml`. To require approval for every change, set `review.required: true`; approval remains off by default. Existing configuration remains unchanged. With `--dry-run`, the target tree remains unchanged after preflight; `--help` reports supported options. Pass `--ci` to also write `.github/workflows/intent-verify.yml` when it is absent: the reference workflow runs the coverage gate on every pull request and on pushes to `main`, then verifies the found record with `--strict`. Commit the adoption as its own change, or declare `AGENTS.md` and `.github/workflows/intent-verify.yml` in the declared scope of the record that carries it.

The installer adds a version-pinned `.intent/` bundle containing the protocol, schemas, project-context prompt, agent guidance, decision index, change templates, the reference change verifier, and the coverage gate. New configuration protects common test paths by default; approval remains off. The pinned copy defines the version a repository's records are written under; upgrading is a deliberate reinstall. It creates or updates only Intent's marked section in root `AGENTS.md`; all surrounding text is preserved. Existing differing managed files (except the intentionally preserved `config.yaml`), symlinks, and malformed markers cause a preflight failure instead of an overwrite unless `--upgrade` is given. Unrelated files are left alone. The installer refuses repositories still on protocol 1.0; migrate those first (see below).

An adoption-ready repository has relevant project facts recorded in `.intent/PROJECT.md`; reviewer identities are needed only for configured approval gates. The installer leaves project-specific facts and language-specific files unchanged. It supplies guidance and records only; filesystem write permissions are enforced only when a controller mediates access. Target files remain unstaged and uncommitted.

## Migrating a protocol 1.0 repository

From a checkout of this repository, run the one-time migrator against a clean working tree:

```sh
sh /path/to/intent/scripts/migrate-v1.sh --target /path/to/your/repository --dry-run
sh /path/to/intent/scripts/migrate-v1.sh --target /path/to/your/repository --ci
```

It moves every record's `change.yaml` into `proposal.md` front matter, preserving bodies and digests byte for byte, so existing approvals stay valid. Text from the v1 mirrors that the body does not already carry is archived to `_v1-notes.md` per record and reported. `config.yaml` keeps its policy and review values, `PROJECT.md` and `decisions/` are untouched, v1-only managed files are removed, and the v2 bundle is installed. Nothing is staged or committed. Commit the migration deliberately; if you record it as a change, include `.github/workflows/intent-verify.yml` in that record's declared scope when `--ci` is used.

## Install with an agent

From inside the repository you want to adopt, paste this into Claude Code, OpenCode, or any agent with shell access:

```text
Clone https://github.com/xpressabhi/intent with --depth 1 to a temporary directory, read docs/install-prompt.md from the clone, and follow it to install Intent in this repository.
```

The prompt runs a dry run first, installs only on a clean preflight, completes `.intent/PROJECT.md` from repository evidence, and reports what is left. Save it as a slash command or skill if you install often.

## Verify changes in CI

Two scripts cover a change range. The coverage gate fails non-documentation changes that carry no record; the verifier checks the record against the diff and runs the repository's checks:

```sh
sh .intent/scripts/verify-records.sh --base origin/main
sh .intent/scripts/verify-change.sh --change .intent/changes/CHG-0001 \
  --base origin/main --strict
```

The coverage gate passes documentation-only changes and record maintenance, requires exactly one record otherwise, and accepts an auditable `Intent-Skip: <reason>` trailer in a commit message when a change is deliberately exempt. The verifier matches declared globs literally, rejects undeclared paths when `scope.paths` is declared, requires every changed protected test to appear in `test_changes` (exact paths or globs), resolves declared links, binds approvals to the body digest, and warns about declared paths that matched nothing. `--change` defaults to the only change record under `.intent/changes/`. Set `policy.verify_command` in `.intent/config.yaml` to omit `--command`; `--baseline` runs the same command at `--base` and fails when the baseline is not green; `--strict` fails when schema validation cannot run; `--print-digest` prints the body digest while authoring a record.

## Adoption checklist

- Fill `.intent/PROJECT.md` with repository facts and reproducible checks.
- Set `policy.verify_command`; keep the default protected test paths or adjust them.
- Decide whether changes require approval: set `review.required: true` and list `authorized_reviewers`; approval binds to the body digest.
- Install the reference CI workflow with `install.sh --ci`, or run `verify-records.sh` and `verify-change.sh --strict` in CI against the change's base revision.
- Keep declarations narrow: prefer exact paths or tight globs in `scope.paths`, and declare bulk test edits as one glob entry with a reason.
- When re-opening a measured or reverted decision, link it (`links.related` / `links.supersedes`) or promote it to `.intent/decisions/`.

## Project status

This repository contains the v2 protocol, schemas, conformance scenarios, a generic repository installer with an optional reference CI workflow, the reference change verifier and coverage gate, and a one-time v1-to-v2 migrator. It does not yet provide a CLI, controller, agent adapter, Git provider integration, or hosted service. The verifier provides checkable enforcement for declared changes, protected paths, links, lifecycle state, and approval evidence; controller enforcement remains future work.

## License

MIT — see [LICENSE](LICENSE).
