# Task Completion Checklist for sync-tools

Before claiming a task is complete:
1. **Verify Implementation**: Ensure all requirements are met.
2. **Check for Duplication**: Ensure no logic or workflow steps are duplicated (DRY).
3. **Check SSOT**: Ensure single source of truth is maintained.
4. **Run Diagnostics**: Use `lsp_diagnostics` on modified files.
5. **Verify Workflows**: If possible, ensure GitHub Actions workflows are syntactically correct.
6. **Commit Changes**: Use conventional commit messages.
7. **Update Documentation**: If the change affects public interfaces or usage, update `README.md` or `IMAGE_SYNC_GUIDE.md`.
