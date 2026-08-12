# One-command test run for the mORMot / FPC Win64 CallMethod unwind
# reproducer.
#
# Default workflow:
#   1. fetch/verify the pinned mORMot2 dependency (tools/get-mormot.ps1);
#   2. install the MASM replacement trampoline (tools/prepare.ps1);
#   3. force-rebuild the test executable with FPC 3.2.2 Win64 (-B -Xm,
#      internal linker, dedicated PPU directory, repository-only unit paths);
#   4. run the binary unwind verification (tools/check-unwind.ps1) BEFORE the
#      raising suite;
#   5. run the complete runtime/ABI suite (12 cases, 1000 sequential unwind
#      cycles, concurrency, post-stress call);
#   6. restore the pristine pinned dependency in a finally block.
#
# -PristineRepro instead demonstrates the ORIGINAL problems against pristine
# pinned mORMot: the same suite is compiled without the fix (verbose mode)
# and is expected to report Currency 1234.5678 -> 0 and to terminate on the
# first ordinary service exception. The observed exception code is
# diagnostic-only and intentionally not asserted.
#
# Usage:
#   pwsh tools/run-tests.ps1 [-FpcPath <fpc.exe>] [-Ml64Path <ml64.exe>]
#                            [-DumpbinPath <dumpbin.exe>] [-NoRestore]
#   pwsh tools/run-tests.ps1 -PristineRepro [-FpcPath <fpc.exe>]

param(
    [switch]$PristineRepro,
    [switch]$NoRestore,
    [string]$FpcPath,
    [string]$Ml64Path,
    [string]$DumpbinPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Fail([string]$Message) {
    throw "[run-tests] $Message"
}

function Resolve-Fpc([string]$ExplicitPath) {
    $candidates = @()
    if ($ExplicitPath) {
        $resolved = Resolve-Path -LiteralPath $ExplicitPath -ErrorAction SilentlyContinue
        if (($null -eq $resolved) -or
            -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
            Fail "explicit fpc was not found: $ExplicitPath"
        }
        $candidates += $resolved.Path
    }
    else {
        $command = Get-Command fpc.exe -CommandType Application `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { $candidates += $command.Source }
        # common Win64 FPC/Lazarus install locations; the PATH fpc is often
        # the i386 cross-compiler even on x64 Lazarus installs
        $candidates += @(
            'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
            'C:\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
            'C:\dev\IDE\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
        )
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $version = (& $candidate -iV 2>$null | Select-Object -First 1)
        $targetOs = (& $candidate -iTO 2>$null | Select-Object -First 1)
        $targetCpu = (& $candidate -iTP 2>$null | Select-Object -First 1)
        if ($null -eq $version) { continue }
        $version = $version.Trim()
        $targetOs = "$targetOs".Trim().ToLowerInvariant()
        $targetCpu = "$targetCpu".Trim().ToLowerInvariant()
        if (($targetOs -ne 'win64') -or ($targetCpu -ne 'x86_64')) {
            Write-Host "[run-tests] skipping $candidate (target $targetOs/$targetCpu, need win64/x86_64)"
            continue
        }
        if ($version -ne '3.2.2') {
            Write-Host "[run-tests] skipping $candidate (version $version; the tested configuration is FPC 3.2.2)"
            continue
        }
        return $candidate
    }
    Fail 'no FPC 3.2.2 Win64/x86_64 compiler found; pass -FpcPath <path\to\x86_64-win64\fpc.exe>'
}

function Invoke-FpcBuild([string]$Fpc, [string]$PpuDir, [string]$BinDir,
    [string[]]$Defines, [string]$LogPath) {
    foreach ($dir in @($PpuDir, $BinDir)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
        New-Item -ItemType Directory -Force $dir | Out-Null
    }
    $fpcArgs = @('-Sh', '-B', '-Xm') + $Defines + @(
        "-FU$PpuDir", "-FE$BinDir",
        '-Fideps/mormot2/src',
        '-Fudeps/mormot2/src/core', '-Fudeps/mormot2/src/lib',
        '-Fudeps/mormot2/src/crypt', '-Fudeps/mormot2/src/net',
        '-Fudeps/mormot2/src/db', '-Fudeps/mormot2/src/orm',
        '-Fudeps/mormot2/src/rest', '-Fudeps/mormot2/src/soa',
        '-Fldeps/mormot2/static/x86_64-win64',
        'test/callmethod_unwind_test.pas'
    )
    Write-Host "[run-tests] $Fpc $($fpcArgs -join ' ')"
    & $Fpc @fpcArgs 2>&1 | Tee-Object -FilePath $LogPath
    if ($LASTEXITCODE -ne 0) { Fail "FPC compile failed (log: $LogPath)" }

    # unit provenance: the tested mormot.core.interfaces must come from the
    # repository checkout and only from the dedicated PPU directory -- a
    # stale PPU elsewhere could silently mask the conditional replacement
    $compileLog = Get-Content -LiteralPath $LogPath -Raw
    if ($compileLog -notmatch
        'Compiling .*deps[\\/]mormot2[\\/]src[\\/]core[\\/]mormot\.core\.interfaces\.pas') {
        Fail 'compile did not (re)build repository mormot.core.interfaces.pas'
    }
    $expectedPpu = Join-Path $PpuDir 'mormot.core.interfaces.ppu'
    if (-not (Test-Path -LiteralPath $expectedPpu -PathType Leaf)) {
        Fail "expected PPU missing: $expectedPpu"
    }
    $strays = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File `
        -Filter mormot.core.interfaces.ppu -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike (Join-Path $RepoRoot 'build\*')
        })
    if ($strays.Count -ne 0) {
        Fail "stray mormot.core.interfaces.ppu outside build/: $($strays.FullName -join '; ')"
    }
}

$fpc = Resolve-Fpc $FpcPath
Write-Host "[run-tests] fpc: $fpc ($((& $fpc -iV).Trim()) $((& $fpc -iTP).Trim())-$((& $fpc -iTO).Trim()))"

Push-Location $RepoRoot
try {
    if ($PristineRepro) {
        # ---- original-bug demonstration against pristine pinned mORMot ----
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'tools\get-mormot.ps1')
        if ($LASTEXITCODE -ne 0) { Fail 'dependency fetch/verify failed' }

        $ppuDir = Join-Path $RepoRoot 'build\pristine-fpc'
        $binDir = Join-Path $RepoRoot 'build\pristine-bin'
        $logPath = Join-Path $RepoRoot 'build\pristine-compile.log'
        New-Item -ItemType Directory -Force (Join-Path $RepoRoot 'build') | Out-Null
        Invoke-FpcBuild $fpc $ppuDir $binDir `
            @('-dCALLMETHOD_PRISTINE_DIFFERENTIAL', '-dCALLMETHOD_VERBOSE') `
            $logPath

        $exe = Join-Path $binDir 'callmethod_unwind_test.exe'
        Write-Host ''
        Write-Host '[run-tests] running the suite against PRISTINE pinned CallMethod'
        Write-Host '[run-tests] expected: Currency returns 0 and the process terminates'
        Write-Host '[run-tests] on the first ordinary service exception (case 09)'
        Write-Host ''
        $runtimeLines = @(& $exe 2>&1 | ForEach-Object { "$_" })
        $runtimeCode = $LASTEXITCODE
        $runtimeLines | ForEach-Object { Write-Host $_ }
        $runtimeText = $runtimeLines -join "`n"
        Write-Host ''
        Write-Host "[run-tests] pristine process exit code: $runtimeCode"

        $currencyDefect = ($runtimeText -match
            '(?m)^CASE 04 floating-return-kinds\s+FAIL') -and
            ($runtimeText -match [regex]::Escape('{"result":[0]}'))
        $unwindDefect = ($runtimeCode -ne 0) -and
            ($runtimeText -notmatch '12/12 PASS') -and
            ($runtimeText -notmatch '(?m)^CASE 09 ')
        Write-Host ''
        if ($currencyDefect) {
            Write-Host 'PRISTINE ISSUE B REPRODUCED: Currency 1234.5678 -> {"result":[0]}'
        }
        else {
            Write-Host 'PRISTINE ISSUE B NOT REPRODUCED: Currency did not return 0'
        }
        if ($unwindDefect) {
            Write-Host 'PRISTINE ISSUE A REPRODUCED: process terminated before the exception case could complete -- exception propagation cannot safely traverse pristine CallMethod'
            Write-Host '(the exact exception code is environment-dependent and deliberately not asserted)'
        }
        else {
            Write-Host 'PRISTINE ISSUE A NOT REPRODUCED: the exception case ran to completion'
        }
        if ($currencyDefect -and $unwindDefect) {
            Write-Host ''
            Write-Host 'PRISTINE REPRODUCTION: CONFIRMED'
            exit 0
        }
        Write-Host ''
        Write-Host 'PRISTINE REPRODUCTION: NOT CONFIRMED (see output above)'
        exit 1
    }

    # ---- full workflow against the prepared replacement -------------------
    $failed = $false
    try {
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'tools\get-mormot.ps1')
        if ($LASTEXITCODE -ne 0) { Fail 'dependency fetch/verify failed' }

        $prepareArgs = @()
        if ($Ml64Path) { $prepareArgs += @('-Ml64Path', $Ml64Path) }
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'tools\prepare.ps1') @prepareArgs
        if ($LASTEXITCODE -ne 0) { Fail 'preparation failed' }

        $ppuDir = Join-Path $RepoRoot 'build\fpc'
        $binDir = Join-Path $RepoRoot 'build\bin'
        $logPath = Join-Path $RepoRoot 'build\compile.log'
        New-Item -ItemType Directory -Force (Join-Path $RepoRoot 'build') | Out-Null
        Invoke-FpcBuild $fpc $ppuDir $binDir `
            @('-dMORMOT_CALLMETHOD_UNWIND_FIX') $logPath

        $exe = Join-Path $binDir 'callmethod_unwind_test.exe'
        $map = Join-Path $binDir 'callmethod_unwind_test.map'

        $checkArgs = @(
            '-ObjectPath', (Join-Path $RepoRoot 'deps\mormot2\src\core\x64callmethod.obj')
            '-ExecutablePath', $exe
            '-MapPath', $map
        )
        if ($DumpbinPath) { $checkArgs += @('-DumpbinPath', $DumpbinPath) }
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'tools\check-unwind.ps1') @checkArgs
        if ($LASTEXITCODE -ne 0) { Fail 'binary unwind verification failed' }

        $runtimeLines = @(& $exe 2>&1 | ForEach-Object { "$_" })
        $runtimeCode = $LASTEXITCODE
        $runtimeLines | ForEach-Object { Write-Host $_ }
        $runtimeText = $runtimeLines -join "`n"
        if (($runtimeCode -ne 0) -or
            ($runtimeText -notmatch 'CALLMETHOD-UNWIND: 12/12 PASS')) {
            Fail "runtime suite failed (exit $runtimeCode)"
        }

        function CaseVerdict([string]$Number) {
            if ($runtimeText -match "(?m)^CASE $Number \S+\s+PASS") { return 'PASS' }
            return 'FAIL'
        }
        Write-Host ''
        Write-Host 'mORMot/FPC Win64 CallMethod unwind test'
        Write-Host ''
        Write-Host 'ABI:'
        Write-Host '  12/12 PASS'
        Write-Host ''
        Write-Host 'Exception unwind:'
        Write-Host "  single raise $(CaseVerdict '09')"
        Write-Host "  finally markers $(CaseVerdict '09')"
        Write-Host "  sequential 1000/1000 $(CaseVerdict '10')"
        Write-Host "  concurrency $(CaseVerdict '11')"
        Write-Host "  post-stress call $(CaseVerdict '12')"
        Write-Host ''
        Write-Host 'PE unwind metadata:'
        Write-Host '  RUNTIME_FUNCTION PASS'
        Write-Host '  RBP frame PASS'
        Write-Host '  RBP/R12 saves PASS'
        Write-Host ''
        Write-Host 'RESULT:'
        Write-Host '  PASS'
    }
    catch {
        $failed = $true
        throw
    }
    finally {
        if (-not $NoRestore) {
            & pwsh -NoProfile -File (Join-Path $RepoRoot 'tools\restore.ps1')
            if ($LASTEXITCODE -ne 0) {
                Write-Host '[run-tests] WARNING: dependency restore failed'
                if (-not $failed) { Fail 'dependency restore failed' }
            }
        }
        else {
            Write-Host '[run-tests] -NoRestore: dependency left in prepared state'
        }
    }
}
finally {
    Pop-Location
}
