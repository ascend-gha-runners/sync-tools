# Suggested Commands for sync-tools

## Git Operations
- `git status`: Check working tree status.
- `git add <file>`: Stage changes.
- `git commit -m "<type>(<scope>): <subject>"`: Create a conventional commit.
- `git push`: Push changes to remote.

## File Exploration
- `ls -R .github/workflows`: List all workflows and configs.
- `grep -r "docker push" .github/workflows`: Search for docker push commands.
- `grep -r "skopeo copy" .github/workflows`: Search for skopeo copy commands.

## Workflow Management
- Workflows are triggered automatically on push to `main` or can be manually dispatched via the GitHub Actions UI.
