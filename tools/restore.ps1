# Restores deps/mormot2/src/core/mormot.core.interfaces.pas from the exact
# locked git commit and removes the generated x64callmethod.obj, transaction
# leftovers and the dedicated PPU output directories. Never trusts a stale
# .bak file: the pristine content always comes from the pinned git blob.
#
# The recognition, rollback and verification logic is shared with the
# preparation script; this is its restore entry point.
#
# Usage: pwsh tools/restore.ps1

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'prepare.ps1') -Restore
exit $LASTEXITCODE
