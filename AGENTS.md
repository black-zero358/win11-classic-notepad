# Project

Standalone Windows 11 classic Notepad restoration utility. The public entry point is `Restore-ClassicNotepad.ps1`.

## Contracts

- Default mode is read-only inspection. Never run Apply or Appx removal on a development machine as a test.
- Keep Windows PowerShell 5.1 and PowerShell 7 compatibility. Windows Appx/DISM operations run through native Windows PowerShell.
- Match only Microsoft.WindowsNotepad packages. Never force-close applications, change UserChoice hashes, disable security settings, or download replacement system executables.
- Keep registry backup/restore value-scoped. A registry backup is not an Appx package/data backup.
- Distinguish mocked tests, read-only host inspection, and disposable-machine end-to-end acceptance.
- Use uv for Python and pnpm for Node if needed. No Python or Node runtime is required by the delivered script.
- Do not commit local machine snapshots, package inventories, usernames, logs, or backup files.

## Verification

Run `pwsh -NoProfile -File tests/Run-Tests.ps1` and the same test script under Windows PowerShell 5.1. Keep README usage aligned with the script's parameter contract.
