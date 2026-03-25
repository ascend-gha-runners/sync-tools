# Style and Conventions for sync-tools

## Commit Messages
Follow Conventional Commits:
- `feat`: New feature.
- `fix`: Bug fix.
- `refactor`: Code change that neither fixes a bug nor adds a feature.
- `docs`: Documentation only.
- `chore`: Build process or auxiliary tool changes.

## GitHub Actions
- Use Reusable Workflows for common tasks.
- Centralize configurations.
- Ensure fail-safe execution in loops.
- Redirect debug logs to `stderr` for clean `stdout` outputs.

## Bash Scripts
- Use `set -eo pipefail`.
- Include header comments with Purpose, Usage, Arguments, Outputs, and Exit Codes.
- Check for package managers (`yum`, `dnf`, `microdnf`) explicitly.
