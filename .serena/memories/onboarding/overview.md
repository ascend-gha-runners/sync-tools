# Project Onboarding: sync-tools

## Project Purpose
The `sync-tools` project is designed to synchronize Docker images, AI models, and datasets for Ascend (昇腾) hardware. It uses `skopeo` to sync images from primary release registries (like `quay.io/ascend/`) to other registries for easier access. It also automates the downloading and syncing of models and datasets from platforms like ModelScope and HuggingFace.

## Tech Stack
- **Automation**: GitHub Actions (Workflows)
- **Image Syncing**: `skopeo`
- **Scripting**: Bash
- **Configuration**: `.ini` and `.json` files

## Code Style and Conventions
- **Conventional Commits**: `<type>(<scope>): <subject>` (e.g., `feat`, `fix`, `refactor`, `docs`, `chore`).
- **Single Source of Truth (SSOT)**: `AGENTS.md` is the sole source for AI instructions. Centralize project configs in GitHub variables/secrets or dedicated files.
- **DRY (Don't Repeat Yourself)**: Use Reusable Workflows (`on: workflow_call`) and standalone Bash scripts to avoid duplication.
- **Fail-Safe Execution**: Loops should not crash on a single failure. Use `FAIL_COUNT` accumulators and `exit 1` at the end if any item failed.
- **Robust Bash**: Use `set -eo pipefail` for standalone scripts.
- **Documentation**: Reusable scripts and workflows must have comprehensive header comments.

## Codebase Structure
- `.github/workflows/`: GitHub Actions workflow files.
- `.github/workflows/config/`: Configuration files for model and dataset syncing (`.ini`, `.json`).
- `README.md`: Project overview and usage instructions.
- `IMAGE_SYNC_GUIDE.md`: Detailed image registry and naming guide.
- `AGENTS.md`: Core principles and constraints for AI agents.

## Key Commands
- **Image Syncing**: Handled by `skopeo` within GitHub Actions.
- **Model/Dataset Syncing**: Triggered by GitHub Actions based on config changes or manual dispatch.
- **Git**: Standard git commands for version control.
- **Bash**: Standard Linux utilities (`ls`, `grep`, `find`, etc.).
