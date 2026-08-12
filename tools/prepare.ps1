# Installs the Win64 unwind-aware CallMethod replacement into the pinned
# deps/mormot2 checkout, transactionally:
#   1. verifies Windows x64 and the exact locked mORMot commit;
#   2. verifies the pinned source still has the audited CallMethod shape;
#   3. assembles src/x64callmethod.asm with MASM ml64.exe and validates the
#      resulting x64 COFF object (public x64callmethod, .text$mn/.pdata/.xdata);
#   4. installs the object next to mormot.core.interfaces.pas and wraps the
#      original ABIX64 CallMethod block in a conditional guarded by
#      MORMOT_CALLMETHOD_UNWIND_FIX (Windows-x64 FPC only);
#   5. rejects any unknown dependency state and rolls back on failure.
# Idempotent: re-running against the exact generated state succeeds.
#
# Usage: pwsh tools/prepare.ps1 [-Ml64Path <path\to\ml64.exe>]
#        pwsh tools/prepare.ps1 -Restore     (used by tools/restore.ps1)

param(
    [switch]$Restore,
    [string]$Ml64Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LockFile = Join-Path $RepoRoot 'mormot.lock'
$MormotRoot = Join-Path $RepoRoot 'deps\mormot2'
$TargetRelative = 'src/core/mormot.core.interfaces.pas'
$CoreDir = Join-Path $MormotRoot 'src\core'
$PasFile = Join-Path $MormotRoot ($TargetRelative -replace '/', '\')
$ObjFile = Join-Path $CoreDir 'x64callmethod.obj'
$AsmFile = Join-Path $RepoRoot 'src\x64callmethod.asm'
$DedicatedPpuDirs = @(
    Join-Path $RepoRoot 'build\fpc'
    Join-Path $RepoRoot 'build\pristine-fpc'
)
$GeneratedPrefix = 'mormot.core.interfaces.pas.unwind-fix.'
$ObjectGeneratedPrefix = 'x64callmethod.obj.unwind-fix.'
$SourceTransactionPattern =
    '^src/core/mormot\.core\.interfaces\.pas\.unwind-fix\.[0-9a-f]{32}\.(new|backup)$'
$ObjectTransactionPattern =
    '^src/core/x64callmethod\.obj\.unwind-fix\.[0-9a-f]{32}\.new$'

function Fail([string]$Message) {
    throw "[prepare] $Message"
}

function Read-LockFile {
    $result = @{}
    $lineNumber = 0
    foreach ($lineValue in Get-Content -LiteralPath $LockFile) {
        $lineNumber++
        $line = $lineValue.Trim()
        if (($line -eq '') -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '=') {
            Fail "mormot.lock line ${lineNumber} is malformed"
        }
        $key, $value = $line -split '=', 2
        $key = $key.Trim()
        if ($result.ContainsKey($key)) {
            Fail "mormot.lock contains duplicate key '$key'"
        }
        $result[$key] = $value.Trim()
    }
    return $result
}

function Normalize-Newlines([string]$Text) {
    return ($Text -replace "`r`n", "`n") -replace "`r", "`n"
}

function Read-GitBlob([string]$Revision, [string]$RelativePath) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [void]$start.ArgumentList.Add('-C')
    [void]$start.ArgumentList.Add($MormotRoot)
    [void]$start.ArgumentList.Add('show')
    [void]$start.ArgumentList.Add("${Revision}:${RelativePath}")
    $process = [System.Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Fail "unable to read ${Revision}:${RelativePath}: $stderr"
    }
    return Normalize-Newlines $stdout
}

function Assert-PinnedSourceShape([string]$Pristine) {
    # The MASM replacement hard-codes TCallMethodArgs offsets, the 256-byte
    # MAX_EXECSTACK and the imvDouble/imvDateTime/imvCurrency ordinals; the
    # pinned source must still match those audited assumptions.
    $required = @(
        "MAX_METHOD_ARGS = 32;",
        "MAX_EXECSTACK = MAX_METHOD_ARGS * 8; // match .PARAMS 32",
        @'
  TInterfaceMethodValueType = (
    imvNone,
    imvSelf,
    imvBoolean,
    imvEnum,
    imvSet,
    imvInteger,
    imvCardinal,
    imvInt64,
    imvDouble,
    imvDateTime,
    imvCurrency,
'@,
        @'
  TCallMethodArgs = record
    StackSize: PtrInt;
    StackAddr, method: PtrInt;
    ParamRegs: array[PARAMREG_FIRST .. PARAMREG_LAST] of PtrInt;
    {$ifdef HAS_FPREG}
    FPRegs: array[FPREG_FIRST .. FPREG_LAST] of Double;
    {$endif HAS_FPREG}
    res64: Int64Rec;
    resKind: TInterfaceMethodValueType;
  end;
'@
    )
    foreach ($needleValue in $required) {
        $needle = Normalize-Newlines $needleValue
        if (-not $Pristine.Contains($needle)) {
            Fail 'pinned source shape no longer matches the audited ABI/layout assumptions'
        }
    }
}

function Get-PatchedSource([string]$Pristine) {
    Assert-PinnedSourceShape $Pristine
    $start = Normalize-Newlines @'
{$ifdef ABIX64}

{$ifdef NOASMBLOCK}
'@
    $finish = Normalize-Newlines @'
{$endif NOASMBLOCK}
{$endif ABIX64}
'@
    if ($Pristine.Split($start).Count -ne 2) {
        Fail 'expected exactly one audited ABIX64 CallMethod block start'
    }
    $startIndex = $Pristine.IndexOf($start, [StringComparison]::Ordinal)
    $finishIndex = $Pristine.IndexOf($finish, $startIndex,
        [StringComparison]::Ordinal)
    if ($finishIndex -lt 0) {
        Fail 'unable to find the audited ABIX64 CallMethod block end'
    }
    if ($Pristine.IndexOf($finish, $finishIndex + $finish.Length,
            [StringComparison]::Ordinal) -ge 0) {
        Fail 'the audited ABIX64 CallMethod block end is not unique'
    }

    $guard = Normalize-Newlines @'
{$ifdef ABIX64}

{$if defined(FPC) and defined(OSWINDOWS) and defined(MORMOT_CALLMETHOD_UNWIND_FIX)}
{$L x64callmethod.obj}
procedure CallMethod(var Args: TCallMethodArgs); external
  name 'x64callmethod';
{$else}

{$ifdef NOASMBLOCK}
'@
    $guardEnd = Normalize-Newlines @'
{$endif NOASMBLOCK}
{$endif MORMOT_CALLMETHOD_UNWIND_FIX}
{$endif ABIX64}
'@

    $before = $Pristine.Substring(0, $startIndex)
    $bodyStart = $startIndex + $start.Length
    $bodyLength = $finishIndex - $bodyStart
    $body = $Pristine.Substring($bodyStart, $bodyLength)
    $after = $Pristine.Substring($finishIndex + $finish.Length)
    return $before + $guard + $body + $guardEnd + $after
}

function Get-NonStaticStatus {
    $lines = @(& git -C $MormotRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { Fail 'unable to inspect the mORMot checkout' }
    $result = @()
    foreach ($line in $lines) {
        if ($line.Length -lt 4) { Fail "unexpected git status line '$line'" }
        $path = $line.Substring(3).Trim('"') -replace '\\', '/'
        if (($path -eq 'static') -or $path.StartsWith('static/')) { continue }
        $result += [pscustomobject]@{
            Status = $line.Substring(0, 2)
            Path = $path
            Line = $line
        }
    }
    return @($result)
}

function Assert-DependencyState([string]$State) {
    $dirty = @(Get-NonStaticStatus)
    if ($State -eq 'pristine') {
        if ($dirty.Count -ne 0) {
            Fail "dependency has non-static changes: $($dirty.Line -join '; ')"
        }
        return
    }
    if ($State -ne 'patched') { Fail "internal unknown state '$State'" }
    $sourceState = @($dirty | Where-Object { $_.Path -ceq $TargetRelative })
    $objectState = @($dirty | Where-Object {
        $_.Path -ceq 'src/core/x64callmethod.obj'
    })
    if (($dirty.Count -ne 2) -or
        ($sourceState.Count -ne 1) -or ($sourceState[0].Status -ne ' M') -or
        ($objectState.Count -ne 1) -or ($objectState[0].Status -ne '??')) {
        Fail "dependency is not in the exact generated patched state: $($dirty.Line -join '; ')"
    }
}

function Assert-RestoreState([string]$Pristine, [string]$ExpectedPatched) {
    $dirty = @(Get-NonStaticStatus)
    $transactions = @($dirty | Where-Object {
        ($_.Path -cmatch $SourceTransactionPattern) -or
        ($_.Path -cmatch $ObjectTransactionPattern)
    })
    foreach ($item in $dirty) {
        $knownPath = ($item.Path -ceq $TargetRelative) -or
            ($item.Path -ceq 'src/core/x64callmethod.obj') -or
            ($item.Path -cmatch $SourceTransactionPattern) -or
            ($item.Path -cmatch $ObjectTransactionPattern)
        if (-not $knownPath) {
            Fail "restore refuses unrelated dependency change: $($item.Line)"
        }
        if (($item.Path -ceq $TargetRelative) -and
            ($item.Status -notin @(' M', ' D'))) {
            Fail "restore refuses unexpected target status: $($item.Line)"
        }
        if (($item.Path -cne $TargetRelative) -and
            ($item.Status -ne '??')) {
            Fail "restore refuses unexpected generated-file status: $($item.Line)"
        }
    }

    if (Test-Path -LiteralPath $PasFile -PathType Leaf) {
        $target = Normalize-Newlines ([IO.File]::ReadAllText($PasFile))
        if ($target -ceq $Pristine) {
            $targetState = 'pristine'
        }
        elseif ($target -ceq $ExpectedPatched) {
            $targetState = 'patched'
        }
        elseif ($transactions.Count -ne 0) {
            $targetState = 'partial-with-transaction'
        }
        else {
            Fail 'restore target is neither pristine, patched, nor part of a recognized interrupted transaction'
        }
    }
    elseif ($transactions.Count -ne 0) {
        $targetState = 'missing-with-transaction'
    }
    else {
        Fail 'restore target is missing without a recognized transaction artifact'
    }

    $targetEntries = @($dirty | Where-Object { $_.Path -ceq $TargetRelative })
    Write-Host "[restore] recognized state: $targetState; generated=$($dirty.Count - $targetEntries.Count)"
}

function Read-CoffName([byte[]]$Bytes, [int]$Offset, [int]$Length) {
    $count = 0
    while (($count -lt $Length) -and ($Bytes[$Offset + $count] -ne 0)) {
        $count++
    }
    return [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $count)
}

function Assert-CoffObject([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 20) { Fail "OBJ is too small: $Path" }
    if ([BitConverter]::ToUInt16($bytes, 0) -ne 0x8664) {
        Fail "OBJ machine is not AMD64: $Path"
    }
    $sectionCount = [BitConverter]::ToUInt16($bytes, 2)
    $symbolOffset = [BitConverter]::ToUInt32($bytes, 8)
    $symbolCount = [BitConverter]::ToUInt32($bytes, 12)
    $optionalSize = [BitConverter]::ToUInt16($bytes, 16)
    $sectionOffset = 20 + $optionalSize
    if (($sectionCount -eq 0) -or
        ($sectionOffset + (40 * $sectionCount) -gt $bytes.Length)) {
        Fail "OBJ has an invalid section table: $Path"
    }
    $requiredSections = @{}
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $offset = $sectionOffset + (40 * $i)
        $name = Read-CoffName $bytes $offset 8
        $requiredSections[$name] = [pscustomobject]@{
            Name = $name
            RawSize = [BitConverter]::ToUInt32($bytes, $offset + 16)
            RawOffset = [BitConverter]::ToUInt32($bytes, $offset + 20)
            RelocationOffset = [BitConverter]::ToUInt32($bytes, $offset + 24)
            RelocationCount = [BitConverter]::ToUInt16($bytes, $offset + 32)
            Characteristics = [BitConverter]::ToUInt32($bytes, $offset + 36)
        }
    }
    foreach ($name in @('.text$mn', '.pdata', '.xdata')) {
        if (-not $requiredSections.ContainsKey($name)) {
            Fail "OBJ is missing $name`: $Path"
        }
        if ($requiredSections[$name].RawSize -eq 0) {
            Fail "OBJ section $name is empty: $Path"
        }
    }
    $symbolEnd = [uint64]$symbolOffset + ([uint64]18 * $symbolCount)
    if (($symbolOffset -eq 0) -or ($symbolCount -eq 0) -or
        ($symbolEnd + 4 -gt $bytes.Length)) {
        Fail "OBJ has an invalid symbol table: $Path"
    }
    $stringSize = [BitConverter]::ToUInt32($bytes, [int]$symbolEnd)
    if (($stringSize -lt 4) -or ($symbolEnd + $stringSize -gt $bytes.Length)) {
        Fail "OBJ has an invalid string table: $Path"
    }
    $found = $false
    $index = 0
    while ($index -lt $symbolCount) {
        $offset = [int]$symbolOffset + (18 * $index)
        $zeroes = [BitConverter]::ToUInt32($bytes, $offset)
        if ($zeroes -eq 0) {
            $nameOffset = [BitConverter]::ToUInt32($bytes, $offset + 4)
            if (($nameOffset -lt 4) -or ($nameOffset -ge $stringSize)) {
                Fail "OBJ symbol has an invalid string offset: $Path"
            }
            $name = Read-CoffName $bytes ([int]$symbolEnd + [int]$nameOffset) `
                ([int]$stringSize - [int]$nameOffset)
        }
        else {
            $name = Read-CoffName $bytes $offset 8
        }
        $sectionNumber = [BitConverter]::ToInt16($bytes, $offset + 12)
        $storageClass = $bytes[$offset + 16]
        if (($name -ceq 'x64callmethod') -and
            ($sectionNumber -gt 0) -and ($storageClass -eq 2)) {
            $found = $true
        }
        $index += 1 + $bytes[$offset + 17]
    }
    if (-not $found) { Fail "OBJ has no public x64callmethod symbol: $Path" }

    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8, $true)
    try {
        foreach ($name in @('.text$mn', '.pdata', '.xdata')) {
            $section = $requiredSections[$name]
            $writer.Write($name)
            $writer.Write([uint32]$section.Characteristics)
            $writer.Write([uint32]$section.RawSize)
            $writer.Write($bytes, [int]$section.RawOffset, [int]$section.RawSize)
            $relocationBytes = [int]$section.RelocationCount * 10
            $writer.Write([uint32]$relocationBytes)
            if ($relocationBytes -ne 0) {
                $writer.Write($bytes, [int]$section.RelocationOffset,
                    $relocationBytes)
            }
        }
        $writer.Flush()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $fingerprint = [Convert]::ToHexString(
                $sha.ComputeHash($stream.ToArray()))
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
    return [pscustomobject]@{
        Fingerprint = $fingerprint
        Size = $bytes.Length
    }
}

function Resolve-Ml64([string]$ExplicitPath) {
    if ($ExplicitPath) {
        $resolved = Resolve-Path -LiteralPath $ExplicitPath -ErrorAction SilentlyContinue
        if (($null -eq $resolved) -or -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
            Fail "explicit ml64.exe was not found: $ExplicitPath"
        }
        return $resolved.Path
    }
    $command = Get-Command ml64.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }

    if ($env:VCToolsInstallDir) {
        $candidate = Join-Path $env:VCToolsInstallDir 'bin\Hostx64\x64\ml64.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installation = (& $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath).Trim()
        if ($LASTEXITCODE -eq 0 -and $installation) {
            $tools = Join-Path $installation 'VC\Tools\MSVC'
            $candidate = Get-ChildItem -LiteralPath $tools -Directory |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64\ml64.exe' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($candidate) { return $candidate }
        }
    }
    Fail 'ml64.exe not found; pass -Ml64Path or initialize an MSVC x64 environment'
}

if (-not $IsWindows) { Fail 'preparation requires Windows' }
if (([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
        [Runtime.InteropServices.Architecture]::X64) -or
    ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne
        [Runtime.InteropServices.Architecture]::X64)) {
    Fail 'preparation requires a native Windows x64 process'
}
if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) {
    Fail "lock file not found: $LockFile"
}
if (-not (Test-Path -LiteralPath (Join-Path $MormotRoot '.git'))) {
    Fail "mORMot checkout not found (run tools/get-mormot.ps1 first): $MormotRoot"
}
if ((-not $Restore) -and
    (-not (Test-Path -LiteralPath $PasFile -PathType Leaf))) {
    Fail "target source not found: $PasFile"
}

$lock = Read-LockFile
$PinnedCommit = $lock['commit']
if (-not $PinnedCommit -or ($PinnedCommit -cnotmatch '^[0-9a-f]{40}$')) {
    Fail 'mormot.lock does not contain a full lowercase commit SHA'
}
$head = (& git -C $MormotRoot rev-parse HEAD).Trim()
if (($LASTEXITCODE -ne 0) -or ($head -cne $PinnedCommit)) {
    Fail "mORMot HEAD '$head' does not match locked commit '$PinnedCommit'"
}

$pristine = Read-GitBlob $PinnedCommit $TargetRelative
$expectedPatched = Get-PatchedSource $pristine

if ($Restore) {
    Assert-RestoreState $pristine $expectedPatched
    & git -C $MormotRoot checkout --quiet --force $PinnedCommit -- $TargetRelative
    if ($LASTEXITCODE -ne 0) { Fail 'git restore of pinned source failed' }
    if (Test-Path -LiteralPath $ObjFile) { Remove-Item -LiteralPath $ObjFile -Force }
    Get-ChildItem -LiteralPath $CoreDir -Filter "${GeneratedPrefix}*" -File `
        -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -LiteralPath $CoreDir -Filter "${ObjectGeneratedPrefix}*" -File `
        -ErrorAction SilentlyContinue | Remove-Item -Force
    foreach ($ppuDir in $DedicatedPpuDirs) {
        if (Test-Path -LiteralPath $ppuDir) {
            $fullPpuDir = [IO.Path]::GetFullPath($ppuDir)
            $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'build')) +
                [IO.Path]::DirectorySeparatorChar
            if (-not $fullPpuDir.StartsWith($expectedPrefix,
                    [StringComparison]::OrdinalIgnoreCase)) {
                Fail "refusing to remove unexpected PPU path: $fullPpuDir"
            }
            Remove-Item -LiteralPath $fullPpuDir -Recurse -Force
        }
    }
    $restored = Normalize-Newlines ([IO.File]::ReadAllText($PasFile))
    if ($restored -cne $pristine) { Fail 'restored source differs from locked commit' }
    Assert-DependencyState 'pristine'
    Write-Host '[restore] RESTORED pinned source; generated OBJ/temp/PPUs removed'
    exit 0
}

$currentRaw = [IO.File]::ReadAllText($PasFile)
$current = Normalize-Newlines $currentRaw
if ($current -ceq $pristine) {
    $state = 'pristine'
}
elseif ($current -ceq $expectedPatched) {
    $state = 'patched'
}
else {
    Fail 'target source is neither pristine pinned source nor the exact generated patch'
}
Assert-DependencyState $state

if (-not (Test-Path -LiteralPath $AsmFile -PathType Leaf)) {
    Fail "ASM source not found: $AsmFile"
}
$stale = @(
    Get-ChildItem -LiteralPath $CoreDir -Filter "${GeneratedPrefix}*" -File `
        -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $CoreDir -Filter "${ObjectGeneratedPrefix}*" -File `
        -ErrorAction SilentlyContinue
)
if ($stale.Count -ne 0) {
    Fail "stale transaction files exist: $($stale.Name -join ', ')"
}

$ml64 = Resolve-Ml64 $Ml64Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('callmethod-unwind-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$tempObj = Join-Path $tempRoot 'x64callmethod.obj'
try {
    Write-Host "[prepare] assembling with $ml64"
    & $ml64 /nologo /c "/Fo$tempObj" $AsmFile
    if ($LASTEXITCODE -ne 0) { Fail "ml64.exe failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $tempObj -PathType Leaf)) {
        Fail 'ml64.exe reported success without producing an OBJ'
    }
    $tempInfo = Assert-CoffObject $tempObj

    if ($state -eq 'patched') {
        if (-not (Test-Path -LiteralPath $ObjFile -PathType Leaf)) {
            Fail 'patched source has no generated x64callmethod.obj'
        }
        $installedInfo = Assert-CoffObject $ObjFile
        if ($installedInfo.Fingerprint -cne $tempInfo.Fingerprint) {
            Fail 'installed OBJ is not the deterministic output of the audited ASM source'
        }
        Write-Host '[prepare] READY (exact generated state already installed)'
        exit 0
    }
    if (Test-Path -LiteralPath $ObjFile) {
        Fail 'pristine source is accompanied by a stale x64callmethod.obj'
    }

    $transactionId = [guid]::NewGuid().ToString('N')
    $sourceCandidate = Join-Path $CoreDir "${GeneratedPrefix}${transactionId}.new"
    $sourceBackup = Join-Path $CoreDir "${GeneratedPrefix}${transactionId}.backup"
    $objCandidate = Join-Path $CoreDir "x64callmethod.obj.unwind-fix.${transactionId}.new"
    $sourceInstalled = $false
    $objInstalled = $false
    try {
        $newline = if ($currentRaw.Contains("`r`n")) { "`r`n" } else { "`n" }
        $candidateText = $expectedPatched.Replace("`n", $newline)
        [IO.File]::WriteAllText($sourceCandidate, $candidateText,
            [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath $tempObj -Destination $objCandidate
        if ((Normalize-Newlines ([IO.File]::ReadAllText($sourceCandidate))) -cne
            $expectedPatched) {
            Fail 'source candidate verification failed'
        }
        [void](Assert-CoffObject $objCandidate)

        [IO.File]::Replace($sourceCandidate, $PasFile, $sourceBackup, $true)
        $sourceInstalled = $true
        [IO.File]::Move($objCandidate, $ObjFile)
        $objInstalled = $true

        if ((Normalize-Newlines ([IO.File]::ReadAllText($PasFile))) -cne
            $expectedPatched) {
            Fail 'installed source verification failed'
        }
        $installedInfo = Assert-CoffObject $ObjFile
        if ($installedInfo.Fingerprint -cne $tempInfo.Fingerprint) {
            Fail 'installed OBJ hash verification failed'
        }
    }
    catch {
        $failure = $_
        if ($objInstalled -and (Test-Path -LiteralPath $ObjFile)) {
            Remove-Item -LiteralPath $ObjFile -Force
        }
        if ($sourceInstalled -and (Test-Path -LiteralPath $sourceBackup)) {
            if (Test-Path -LiteralPath $PasFile) { Remove-Item -LiteralPath $PasFile -Force }
            [IO.File]::Move($sourceBackup, $PasFile)
        }
        throw $failure
    }
    finally {
        foreach ($file in @($sourceCandidate, $sourceBackup, $objCandidate)) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
    Assert-DependencyState 'patched'

    Write-Host "[prepare] pin     : $PinnedCommit"
    Write-Host '[prepare] source  : exact conditional Windows-x64 patch installed'
    Write-Host "[prepare] object  : AMD64, public x64callmethod, .pdata/.xdata, fingerprint=$($tempInfo.Fingerprint)"
    Write-Host '[prepare] READY'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
