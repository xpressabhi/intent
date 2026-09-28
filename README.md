# Intent

**Clear intent moves. Humans resolve what only humans can decide.**

Intent is a lightweight, agent-independent workflow for turning repository context and a requested outcome into a verified change. Agents handle clear in-scope decisions; people are asked only when ambiguity materially affects the outcome or repository policy reserves a decision for them.

See the [visual overview](docs/index.html) for diagrams of the lifecycle, digest binding, and verifier.

## The rule

The agent adapts the depth of its work to the change: understand, decide, implement, and verify; include release and operations only when requested. It records material decisions, continues safe independent work, and pauses only for a consequential human decision or an explicit repository approval boundary. Verification and traceability remain part of every change.

## Change flow

```text
Inception → Construction → Operations (when in scope)
```

The phases are outcomes, not mandatory documents or approval ceremonies. Routine changes can use a concise record; complex or risky work gets more depth where it helps.

## Ownership

The Intent project defines the protocol, schemas, reference tooling, and adapters. Each target repository owns its decisions, architecture context, and change records under `.intent/`. Project knowledge stays with the codebase, and any capable agent can participate without defining the protocol itself.

## Protocol and schemas

- [Intent Protocol v1](protocol/v1.md) — adaptive lifecycle, human decision boundaries, and conformance evidence.
- [Reference change verifier](scripts/verify-change.sh) — checks a change's declarations, protected paths, and repository checks.
- [Configuration schema](schemas/v1/config.schema.json)
- [Change record schema](schemas/v1/change.schema.json)
- [Review evidence schema](schemas/v1/review.schema.json)
- [Conformance scenarios](conformance/v1/scenarios.md)

## Install in another repository

Intent is language- and build-system-independent. From a checkout of this repository, install its pinned v1 guidance bundle into any Git repository on macOS or Linux:

```sh
sh /path/to/intent/scripts/install.sh --target /path/to/your/repository
```

Installation is successful when the target is a Git repository and `.intent/` contains the version-pinned v1 bundle. Without `--target`, the target is the Git root of the current directory. The installer imports unique owners from the first available `.github/CODEOWNERS`, `CODEOWNERS`, or `docs/CODEOWNERS`; `--reviewer ID` adds explicit owners. If no owners are found, installation continues with a TODO in `.intent/config.yaml`. To require approval for every change, set `review.required: true`; approval remains off by default. Existing configuration remains unchanged. With `--dry-run`, the target tree remains unchanged after preflight; `--help` reports supported options. Re-run with `--upgrade` to move an existing installation to a newer pinned bundle; managed files are replaced while `config.yaml`, `PROJECT.md`, and change records are preserved.

The installer adds a version-pinned `.intent/` bundle containing the protocol, schemas, project-context prompt, agent guidance, decision index, change templates, and the reference change verifier. New configuration protects common test paths by default; approval remains off. The pinned copy defines the version a repository's records are written under; upgrading is a deliberate reinstall. It creates or updates only Intent's marked section in root `AGENTS.md`; all surrounding text is preserved. Existing differing managed files (except the intentionally preserved `config.yaml`), symlinks, and malformed markers cause a preflight failure instead of an overwrite unless `--upgrade` is given. Unrelated files are left alone.

An adoption-ready repository has relevant project facts recorded in `.intent/PROJECT.md`; reviewer identities are needed only for configured approval gates. The installer leaves project-specific facts and language-specific files unchanged. It supplies guidance and records only; filesystem write permissions are enforced only when a controller mediates access. Target files remain unstaged and uncommitted.

## Verify changes in CI

The pinned verifier checks a change's declarations, protected paths, lifecycle state, and approval evidence, then runs the repository's checks:

```sh
sh .intent/scripts/verify-change.sh --change .intent/changes/CHG-0001 \
  --base origin/main --command 'make test' --baseline
```

`--change` defaults to the only change record under `.intent/changes/`. Set `policy.verify_command` in `.intent/config.yaml` to omit `--command`; `--baseline` runs the same command at `--base` and fails when the baseline is not green. Use `--print-digest` when recording `proposal.digest`.

## Adoption checklist

- Fill `.intent/PROJECT.md` with repository facts and reproducible checks.
- Set `policy.verify_command`; keep the default protected test paths or adjust them.
- Decide whether changes require approval: set `review.required: true` and list `authorized_reviewers`; approval binds to the proposal digest.
- Run the verifier in CI against the change's base revision.

## Project status

This repository contains the v1 protocol, schemas, conformance scenarios, a generic repository installer, and a reference change verifier. It does not yet provide a CLI, controller, agent adapter, Git provider integration, or hosted service. The verifier provides checkable enforcement for declared changes, protected paths, lifecycle state, and approval evidence; controller enforcement remains future work.

## License

MIT — see [LICENSE](LICENSE).
