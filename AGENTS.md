# Agent Instructions (AGENTS.md)

This document provides absolute constraints and guidelines for any AI agent operating within the `sync-tools` repository. 
**READ THIS FILE BEFORE EXECUTING ANY TASK.**

## 1. Core Principles: Do Not Violate

*   **Single Source of Truth (SSOT) is Absolute:**
    *   Every piece of logic, configuration, or documentation must have a single, unambiguous, authoritative representation within the repository.
    *   **AI Configs:** `AGENTS.md` is the sole source of truth for AI instructions. If tools require specific filenames (e.g., `CLAUDE.md`, `.cursorrules`), you **MUST** use symlinks. Never duplicate content.
    *   **Project Configs:** Do not hardcode the same values (e.g., registry URLs, base paths) across multiple scripts. Centralize them in GitHub Repository Variables, Secrets, or a dedicated configuration file.
*   **DRY (Don't Repeat Yourself) is Mandatory:** 
    *   Never duplicate GitHub Actions workflow steps across multiple `.yml` files. 
    *   If you find yourself writing the same Bash execution block or environment setup more than once, STOP. Extract it into a Reusable Workflow (`on: workflow_call`) in `.github/workflows/` or a standalone Bash script in `.github/scripts/`.
*   **Fail-Safe Execution (No Silent Failures):** 
    *   When looping through items (e.g., downloading multiple models from `.ini` or `.json` lists), **DO NOT** let a single failure crash the entire loop (due to GitHub Actions' default `set -e`).
    *   **DO NOT** use `|| echo "Failed"` which silently swallows the error and returns a `0` exit code (Green build).
    *   **MUST DO:** Implement a `FAIL_COUNT` accumulator. Catch errors within the loop, increment the counter, continue the loop, and explicitly `exit 1` at the end of the step if `FAIL_COUNT > 0`.

## 2. Documentation & Comments

*   **Public Interfaces Require Documentation:**
    *   Any reusable script (e.g., Bash scripts in `.github/scripts/`) or Reusable Workflow (`.github/workflows/reusable-*.yml`) **MUST** have a comprehensive header comment.
    *   **Workflow Comments MUST include:** `Purpose`, `Key Features`, and explicit descriptions of all `Inputs`.
    *   **Bash Script Comments MUST include:** `Purpose`, `Usage` (with examples), `Arguments`, `Outputs`, and `Exit Codes`.
*   **No Unnecessary Comments:** 
    *   Do not write comments that merely repeat what the code does (e.g., `# Print hello` above `echo "hello"`). Only document the "Why", complex regex, or public API contracts.

## 3. GitHub Actions Specific Rules

*   **Robust Bash Scripts:** Always use `set -eo pipefail` for standalone bash scripts.
*   **Clean Outputs:** When a script is meant to return a value to a GitHub Action variable (e.g., `TAGS=$(bash script.sh)`), ensure all debugging logs or progress indicators are redirected to `stderr` (`>&2`). Only the final pure output should go to `stdout`.
*   **Dependency Management:** Do not rely on implicit package managers. Check for `yum`, `dnf`, or `microdnf` explicitly if the base image is not guaranteed to be Debian/Ubuntu.

## 4. Git & Commit Message Conventions

*   Follow the **Conventional Commits** specification.
*   **Format:** `<type>(<scope>): <subject>`
    *   `feat`: A new feature (e.g., adding a new model to sync).
    *   `fix`: A bug fix.
    *   `refactor`: A code change that neither fixes a bug nor adds a feature (e.g., extracting a reusable workflow).
    *   `docs`: Documentation only changes.
    *   `chore`: Changes to the build process or auxiliary tools.
*   **Body:** If the commit is complex, provide a bulleted list in the commit body explaining *what* was changed and *why*.
    *   *Example:*
        ```text
        refactor: extract reusable workflows to reduce duplication
        
        - Added reusable-sync-models-datasets.yml for centralized syncing
        - Extracted inline bash to fetch_dockerhub_tags.sh
        - Improved fault tolerance with cumulative failure exit codes
        ```