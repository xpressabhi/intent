# Install Intent

Agent instructions for adding the Intent v2 bundle to an existing Git repository. A human starts this by pasting the one-line prompt from the README; this file is what the agent follows.

## Goal

Install the pinned Intent v2 bundle into the current repository so changes are recorded, approved when policy requires it, and verified: `.intent/` records, guidance in the root `AGENTS.md`, the reference verifier and coverage gate, and optionally the reference CI workflow.

## Preconditions

- The current working directory is inside the target Git repository.
- macOS or Linux with POSIX `sh`. On Windows, use WSL or Git Bash.
- Either a local Intent checkout path from the user, or network access to clone `https://github.com/xpressabhi/intent`.

## Steps

1. Locate an Intent checkout. Use a local path when the user provides one. Otherwise clone into a temporary directory and keep that path:
   ```sh
   checkout=$(mktemp -d)/intent
   git clone --depth 1 https://github.com/xpressabhi/intent "$checkout"
   ```
   A shallow clone is enough: the installer reads only the current files, never history.
2. Inspect before writing. From the target repository root, run:
   ```sh
   sh "$checkout/scripts/install.sh" --target . --dry-run
   ```
   Read the planned changes. If preflight reports a conflict (a differing managed file, a symlink, or malformed `AGENTS.md` markers), stop and report it. Do not work around it. If the target is still on protocol 1.0, the installer refuses it: stop and follow step 8's migration path instead.
3. Install:
   ```sh
   sh "$checkout/scripts/install.sh" --target .
   ```
   Add `--ci` to also install the reference workflow at `.github/workflows/intent-verify.yml` when that file is absent. Add `--reviewer ID` once per reviewer when the repository should require approval for every change; installs without it keep approval off.
4. Verify the installation:
   - `.intent/` contains `config.yaml`, `PROJECT.md`, `AGENT_GUIDE.md`, `protocol/v2.md`, `schemas/v2/`, `scripts/verify-change.sh`, `scripts/verify-records.sh`, `decisions/`, and `changes/TEMPLATE/`.
   - `AGENTS.md` contains one managed block between `<!-- intent:managed:start -->` and `<!-- intent:managed:end -->`, with all other text preserved.
   - A second `--dry-run` reports only "keep existing" lines.
   - With `--ci`: `.github/workflows/intent-verify.yml` exists and invokes both `.intent/scripts/verify-records.sh` and `.intent/scripts/verify-change.sh`.
5. Complete `.intent/PROJECT.md` from repository evidence: purpose and users, architecture, constraints, reproducible build/test/lint commands, and conventions. Do not invent facts. Leave `TODO` where the repository does not answer and list what remains as follow-ups.
6. Configure verification. Set `policy.verify_command` in `.intent/config.yaml` to the repository's test command, for example `make test` or `npm test`. Keep the default protected test paths and exempt globs unless the repository needs different ones.
7. Leave everything unstaged and report to the user:
   - files created and the managed `AGENTS.md` section,
   - any `TODO` left in `PROJECT.md`,
   - the configured `verify_command`,
   - whether approval is required and which reviewers are configured,
   - whether the CI workflow was installed; if not, the suggested CI step is `sh .intent/scripts/verify-records.sh --base <default branch>` followed by `sh .intent/scripts/verify-change.sh --change <record> --strict`.
8. Upgrade and migration:
   - To move an existing v2 installation to a newer pinned bundle: `sh "$checkout/scripts/install.sh" --target . --upgrade`. Managed files are replaced; `config.yaml`, `PROJECT.md`, and change records are preserved.
   - To migrate a protocol 1.0 repository:
     ```sh
     sh "$checkout/scripts/migrate-v1.sh" --target . --dry-run
     sh "$checkout/scripts/migrate-v1.sh" --target . --ci
     ```
     The migrator requires a clean working tree, moves every record to the v2 shape with digests and approval evidence preserved, archives unmatched v1 mirror text to `_v1-notes.md` per record (and reports it), removes v1-only managed files, and installs the v2 bundle. Nothing is staged or committed. Commit the migration deliberately; if you record it as a change, include `.github/workflows/intent-verify.yml` in that record's declared scope when `--ci` is used.

## Constraints

- Do not stage, commit, or push anything. The installer and migrator never do.
- Do not modify files outside `.intent/`, the managed `AGENTS.md` block, and (with `--ci`) the reference workflow path.
- Do not force an install over a conflict, and do not run the installer against a protocol 1.0 tree — migrate it first.
- Ask the user only for decisions the repository cannot answer: reviewer identities, whether approval is required, and the verification command when it is not discoverable.
