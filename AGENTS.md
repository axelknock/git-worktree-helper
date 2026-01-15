# Repository Guidelines

## Project Structure & Module Organization
- `git-worktree-helper.sh` is the core shell implementation (functions prefixed with `_wt_`).
- `git-worktree-helper-tests.bats` contains the Bats test suite.
- `flake.nix` provides Nix packaging and Home Manager integration.
- `README.md` documents install and usage examples.

## Build, Test, and Development Commands
- `bats git-worktree-helper-tests.bats` runs the test suite.
- `source git-worktree-helper.sh` loads the helper into your shell for manual testing.
- `nix develop` (if you use Nix) opens a dev shell from `flake.nix`.

## Coding Style & Naming Conventions
- Shell code uses 4-space indentation and `[[ ... ]]`/`local` style typical of bash/zsh.
- Helper functions are private and prefixed with `_wt_`; CLI entrypoints are `git-worktree-helper` and `gwh`.
- Prefer clear, imperative messages and short option names that mirror existing flags (e.g., `--force`, `--keep`).

## Testing Guidelines
- Tests use Bats (`#!/usr/bin/env bats`).
- Name new tests in `git-worktree-helper-tests.bats` with descriptive titles.
- Use temporary repos/worktrees under `/tmp` to keep tests hermetic.

## Commit & Pull Request Guidelines
- Commit messages generally follow a Conventional Commits flavor like `feat(pr): add worktree PR command` or `fix(nix): ...` when applicable.
- Keep commits focused on one logical change.
- PRs should include a brief description, the test command run (e.g., `bats git-worktree-helper-tests.bats`), and note any behavior changes.

## Configuration Tips
- `GIT_WORKTREE_DEFAULT_PATH` must be set for `new` and `delete` to work.
- Set `WT_DEBUG=1` to enable debug logging.
- `gwh pr` requires GitHub CLI (`gh`) to be installed.
