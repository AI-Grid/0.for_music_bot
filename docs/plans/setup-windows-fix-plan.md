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
   - Confirm the script must succeed when launched from any drive, fail fast without admin rights, and produce synchronized console/log/Event Viewer messages.
   - Define regression checklist: Git/Node/Python provisioning, backend venv + pip install, frontend `npm install`, `.env` hydration, post-run prompts.

2. **Author Portable PowerShell Bootstrap (`scripts/windows/setup-windows.ps1`)**
   - Compose a PowerShell script that encapsulates the shared behaviors described in the research docs: `$PSScriptRoot` path anchoring, `Ensure-Admin`, `Test-Winget`, version gating (Node ≥ 24.10, Python ≥ 3.14), and dual logging.
   - Implement Result-pattern style returns (boolean flag + message object) instead of relying on thrown exceptions for expected states (network offline, winget missing).
   - Reuse the existing batch flow (backend, frontend, environment files, summary prompt) but with functions scoped per responsibility (`installPrerequisites`, `provisionBackend`, `provisionFrontend`, `ensureEnvFiles`).

3. **Convert Batch Script into Thin PowerShell Launcher (`scripts/windows/setup-windows.bat`)**
   - Replace the legacy batch logic with a short shim that:
     - Ensures PowerShell 5+ is available.
     - Elevates if required.
     - Invokes `setup-windows.ps1 -ExecutionPolicy Bypass` from the same directory, passing through exit codes.
     - Prints actionable guidance if PowerShell execution policy blocks the run.

4. **Documentation Updates**
   - Revise onboarding instructions (e.g., `README.md` or dedicated setup docs) to reference the PowerShell script as the canonical entry point while noting the batch shim for automation-link compatibility.
   - Document prerequisite commands for first-time users (e.g., `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`) and the location of generated logs.

5. **Validation**
   - Smoke test on a clean Windows VM profile: run the new batch shim from multiple directories (user profile, external drive) and confirm idempotent success.
   - Verify log generation (`scripts/windows/logs/*.log`) and Event Viewer entries (`Application` log, source `Suno Automation Setup`).

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

This hard-codes the project path to `%USERPROFILE%`, couples multiple responsibilities into one file, and makes the batch file the single point of failure. The plan delegates these concerns to the new PowerShell implementation.

- `scripts/windows/setup-windows.ps1` (new file) to host the migrated logic.
- `README.md` (or onboarding doc) for usage notes.

## Open Questions
- Do we need to keep the legacy batch logic available behind a flag for backward compatibility with automation pipelines?
- Should the PowerShell script offer non-interactive mode (e.g., `-NoPrompt`) for CI usage, or can that be deferred?

## Verification Checklist
- `scripts/windows/setup-windows.bat` launches PowerShell script successfully from arbitrary working directories.
- PowerShell script installs/updates Git, Node, Python when versions are below the thresholds.
- Backend venv commands run via direct path invocation (no activate/deactivate reliance).
- Frontend dependency installation uses local `npm` from the updated PATH.
- `.env` files are created only when missing and retain existing contents otherwise.
- Console, log file, and Event Viewer entries show consistent status messages.
