<!--
System: Suno Automation
Module: Windows Setup Automation
File URL: docs/plans/setup-windows-fix-plan.md
Purpose: Action plan to remediate scripts/windows/setup-windows.bat via PowerShell migration
-->

# Setup Script Remediation Plan

## Research Synthesis
- **docs/plans/script-research-1.md** stresses that the batch script fails when run outside the user profile, mishandles virtual environments, and cannot deactivate correctly under PowerShell. It recommends a PowerShell rewrite with path discovery via `$MyInvocation.MyCommand.Path`, direct venv invocation, and structured logging.
- **docs/plans/script-research-2.md** contributes a portable PowerShell prototype with admin, network, and winget checks, plus shared logging to file/Event Viewer and post-install menu parity.
- **docs/plans/script-research-3.md** documents systemic batch weaknesses (fragile `%CD%`, opaque error handling, lack of prerequisite gating) and codifies target characteristics: portability, idempotence, dependency self-healing, and dual-channel logging.

## Objective
Deliver a minimum-viable replacement for `scripts/windows/setup-windows.bat` that preserves the one-click developer experience while eliminating the batch-specific reliability gaps surfaced in the research.

## Proposed Implementation Steps
1. **Baseline & Acceptance Criteria (docs only)**
   - Confirm the script succeeds when launched from any drive, fails fast without admin rights, warns on blocked execution policy, and produces synchronized console/log/Event Viewer messages.
   - Document intentional breaking changes: repository clone path resolves relative to the script directory (no `%USERPROFILE%` default), the legacy `deactivate` call is removed, and PATH refresh relies on installer behavior (users may need a new shell).
   - Define regression checklist: Git/Node/Python provisioning with accurate version parsing, backend venv + pip install from the backend directory using Python 3.14, frontend dependency install (`npm ci` when lockfile exists), `.env` hydration, post-run prompts, and non-interactive flows.

2. **Author Portable PowerShell Bootstrap (`scripts/windows/setup-windows.ps1`)**
   - Compose a PowerShell script that encapsulates the shared behaviors described in the research docs: `$PSScriptRoot` (with `$MyInvocation.MyCommand.Path` fallback) path anchoring, `Ensure-Admin`, HTTP-based connectivity checks, `Test-Winget`, and dual logging with resilient Event Log registration (attempt `New-EventLog`/`Write-EventLog`, fall back to `eventcreate`, and degrade gracefully without admin rights).
   - Anchor repository management around `$ProjectRoot = Join-Path $PSScriptRoot $repoName`; handle "directory exists without .git" as a guarded failure and make repo refresh idempotent (`git -C ... fetch --all --prune`, `git -C ... pull --ff-only`) when `.git` is present.
   - Enforce version gating with robust parsers (Node >= 24.10.x, Python >= 3.14.x) and idiomatic error handling: use `$LASTEXITCODE` for external commands plus `Try/Catch -ErrorAction Stop` for cmdlets, logging failures and aborting downstream steps when prerequisites fail.
   - Detect/install Python 3.14 via the `py` launcher or discovered interpreter path, create the backend venv with that interpreter, and run backend installs through `.\backend\.venv\Scripts\pip.exe` so activation/deactivation scripts are unnecessary.
   - Handle winget install vs upgrade explicitly (`winget list` before acting, inspect documented return codes, capture stderr) and short-circuit backend/frontend setup if prerequisites fail to ensure clear rollback behavior.
   - Reuse the batch flow (backend, frontend, environment files, summary prompt) with scoped functions (`installPrerequisites`, `provisionBackend`, `provisionFrontend`, `ensureEnvFiles`) and add switches such as `-NoPrompt` for CI usage while optionally layering progress/transcript capture.

3. **Convert Batch Script into Thin PowerShell Launcher (`scripts/windows/setup-windows.bat`)**
   - Replace the legacy batch logic with a short shim that:
     - Prefers `pwsh.exe` when available, otherwise falls back to Windows PowerShell.
     - Self-elevates with `Start-Process ... -Verb RunAs` when not running as admin.
     - Invokes `setup-windows.ps1` beside the shim with `-NoProfile -ExecutionPolicy Bypass`, forwards arguments such as `-NoPrompt`, and propagates the exit code.
     - Prints actionable guidance if PowerShell execution policy blocks the run, including the command `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`.

4. **Documentation Updates**
   - Revise onboarding instructions (e.g., `README.md` or dedicated setup docs) to reference the PowerShell script as the canonical entry point while noting the batch shim for automation-link compatibility.
   - Document prerequisite commands for first-time users, the new clone-location behavior, removal of `deactivate`, optional `-NoPrompt` usage, PATH refresh expectations, and the location of generated logs/Event Viewer entries.
   - Provide rollback guidance: e.g., rerun after resolving missing prerequisites, consult the log for the last successful phase, and note that previously created `.venv` directories are preserved.

5. **Validation**
   - Smoke test on a clean Windows VM profile: run the new batch shim from multiple directories (user profile, external drive) and confirm idempotent success, including a second run with no changes.
   - Verify log generation (`scripts/windows/logs/*.log`), transcript capture (if enabled), and Event Viewer entries (`Application` log, source `Suno Automation Setup`), including degradation behavior when not run as admin.
   - Exercise `-NoPrompt` mode to ensure non-interactive runs exit cleanly with accurate status codes for CI/CD, and confirm external version checks report the upgraded toolchain.

## Impacted Files & Current Context
- `scripts/windows/setup-windows.bat` (full rewrite into shim). Key fragile region today (`scripts/windows/setup-windows.bat:6-120`):

```bat
set "strProjectRoot=%USERPROFILE%\%strRepoName%"
...
call :setupRepository
...
call :setupBackend
call :setupFrontend
call :setupEnvironmentFiles
```

This hard-codes the project path to `%USERPROFILE%`, couples multiple responsibilities into one file, misuses `deactivate`, and makes the batch file the single point of failure. The replacement shim simply launches the PowerShell implementation and documents the breaking change whereby repositories clone beside the script (`$PSScriptRoot`).

- `scripts/windows/setup-windows.ps1` (new file) to host the migrated logic, including `.git`-aware idempotence checks, resilient logging, and the non-interactive flag.
- `README.md` (or onboarding doc) for usage notes and updated troubleshooting guidance (execution policy, new clone location, PATH refresh expectations).

## Decisions & Open Considerations
- The legacy batch logic will **not** be retained behind a flag; the shim preserves entry-point compatibility without duplicating behavior.
- The PowerShell script **will** support a `-NoPrompt` (or `-NonInteractive`) switch from the first release to unblock CI/CD and unattended execution.
- Decide whether to refresh PATH for the current process after installing prerequisites or to instruct users to open a new shell; document whichever approach is chosen so behavior is predictable.

## Verification Checklist
- `scripts/windows/setup-windows.bat` launches the PowerShell script successfully from arbitrary working directories and propagates exit codes.
- PowerShell script installs/updates Git, Node, Python when versions are below the thresholds and records accurate version detection (e.g., parses `v22.19.0`, upgrades Python 3.13.x to 3.14.x).
- Backend venv commands run via direct path invocation (no activate/deactivate reliance) using the targeted 3.14 interpreter, and `pip install -r requirements.txt` executes from the backend directory.
- Frontend dependency installation uses `npm ci` when a lockfile exists, otherwise `npm install`, and clearly logs the chosen mode.
- `.env` files are created only when missing and retain existing contents otherwise.
- Console, log file, and (when elevated) Event Viewer entries show consistent status messages; when not elevated the script continues with file logging and surfaces the limitation.
- Running the script twice in succession succeeds without errors, leaving the repository, venv, and dependencies in a consistent state.
- `-NoPrompt` execution exits without awaiting input and returns non-zero status codes on failure so CI/CD can react appropriately.
