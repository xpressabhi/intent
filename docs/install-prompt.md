# Install Intent

Agent instructions for adding the Intent v1 bundle to an existing Git repository. A human starts this by pasting the one-line prompt from the README; this file is what the agent follows.

## Goal

Install the pinned Intent v1 bundle into the current repository so changes are recorded, approved when policy requires it, and verified: `.intent/` records, guidance in the root `AGENTS.md`, and the reference change verifier.

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
2. Inspect before writing. From the target repository root, run:
   ```sh
   sh "$checkout/scripts/install.sh" --target . --dry-run
   ```
   Read the planned changes. If preflight reports a conflict (a differing managed file, a symlink, or malformed `AGENTS.md` markers), stop and report it. Do not work around it.
3. Install:
   ```sh
   sh "$checkout/scripts/install.sh" --target .
   ```
   Add `--reviewer ID` once per reviewer when the repository should require approval for every change; installs without it keep approval off.
4. Verify the installation:
   - `.intent/` contains `config.yaml`, `PROJECT.md`, `AGENT_GUIDE.md`, `protocol/v1.md`, `schemas/v1/`, `scripts/verify-change.sh`, `decisions/`, and `changes/TEMPLATE/`.
   - `AGENTS.md` contains one managed block between `<!-- intent:managed:start -->` and `<!-- intent:managed:end -->`, with all other text preserved.
   - A second `--dry-run` reports only "keep existing" lines.
5. Complete `.intent/PROJECT.md` from repository evidence: purpose and users, architecture, constraints, reproducible build/test/lint commands, and conventions. Do not invent facts. Leave `TODO` where the repository does not answer and list what remains as follow-ups.
6. Configure verification. Set `policy.verify_command` in `.intent/config.yaml` to the repository's test command, for example `make test` or `npm test`. Keep the default protected test paths unless the repository needs different globs.
7. Leave everything unstaged and report to the user:
   - files created and the managed `AGENTS.md` section,
   - any `TODO` left in `PROJECT.md`,
   - the configured `verify_command`,
   - whether approval is required and which reviewers are configured,
   - the suggested CI step: run `.intent/scripts/verify-change.sh --base <default branch>` on changes.

## Constraints

- Do not stage, commit, or push anything. The installer never does.
- Do not modify files outside `.intent/` and the managed `AGENTS.md` block.
- Do not force an install over a conflict. Report it and stop.
- Ask the user only for decisions the repository cannot answer: reviewer identities, whether approval is required, and the verification command when it is not discoverable.

## Upgrade

To move an existing installation to a newer pinned bundle:
```sh
sh "$checkout/scripts/install.sh" --target . --upgrade
```
Managed files are replaced; `config.yaml`, `PROJECT.md`, and change records are preserved.
