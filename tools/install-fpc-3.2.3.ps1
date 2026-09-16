param(
    [string]$SourceCommit = '483299735faef392a746646bb3d5f5737a9e53a5',
    [string]$BootstrapFpc,
    [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    throw "[fpc-3.2.3] $Message"
}

function Invoke-Checked([string]$Description, [scriptblock]$Command) {
    Write-Host "[fpc-3.2.3] $Description"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        Fail "$Description failed with exit code $LASTEXITCODE"
    }
}

function Resolve-Bootstrap([string]$ExplicitPath) {
    $candidates = @()
    if ($ExplicitPath) {
        $candidates += $ExplicitPath
    }
    else {
        foreach ($name in 'fpc', 'fpc.exe') {
            $command = Get-Command $name -CommandType Application `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command) { $candidates += $command.Source }
        }
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $version = (& $candidate -iV 2>$null | Select-Object -First 1)
        if ("$version".Trim() -eq '3.2.2') { return $candidate }
    }
    Fail 'the FPC 3.2.2 bootstrap compiler was not found'
}

function Resolve-Application([string[]]$Names, [string[]]$Paths) {
    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { return $command.Source }
    }
    return $null
}

if ($SourceCommit -notmatch '^[0-9a-f]{40}$') {
    Fail 'SourceCommit must be a full 40-character Git SHA'
}

$Bootstrap = Resolve-Bootstrap $BootstrapFpc
$BootstrapDir = Split-Path -Parent $Bootstrap
$TargetOs = "$( & $Bootstrap -iTO )".Trim().ToLowerInvariant()
$TargetCpu = "$( & $Bootstrap -iTP )".Trim().ToLowerInvariant()
$Target = "$TargetCpu-$TargetOs"
if ($TargetOs -notin @('win64', 'linux', 'darwin')) {
    Fail "unsupported native target $Target"
}
if ($TargetCpu -notin @('x86_64', 'aarch64')) {
    Fail "unsupported native CPU $TargetCpu"
}

$PpName = if ($TargetCpu -eq 'aarch64') { 'ppca64' } else { 'ppcx64' }
$ExecutableSuffix = if ($TargetOs -eq 'win64') { '.exe' } else { '' }
$Pp = Resolve-Application @("$PpName$ExecutableSuffix", $PpName) @(
    (Join-Path $BootstrapDir "$PpName$ExecutableSuffix"),
    (Join-Path "/usr/local/lib/fpc/3.2.2" $PpName),
    (Join-Path "/usr/lib/fpc/3.2.2" $PpName)
)
if (-not $Pp) { Fail "bootstrap backend $PpName was not found" }

$Make = Resolve-Application @('gmake', 'make', 'mingw32-make') @(
    (Join-Path $BootstrapDir 'make.exe'),
    (Join-Path $BootstrapDir 'gmake.exe')
)
if (-not $Make) { Fail 'GNU make was not found' }

if (-not $Destination) {
    $Destination = Join-Path ([IO.Path]::GetTempPath()) "fpc-3.2.3-$Target"
}
$Destination = [IO.Path]::GetFullPath($Destination)
$Source = Join-Path ([IO.Path]::GetTempPath()) "fpc-source-$($SourceCommit.Substring(0, 12))-$Target"

foreach ($path in @($Source, $Destination)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $Source, $Destination | Out-Null

Invoke-Checked 'initializing the official FPC source checkout' {
    & git -C $Source init --quiet
}
Invoke-Checked 'adding the official FPC source remote' {
    & git -C $Source remote add origin https://gitlab.com/freepascal.org/fpc/source.git
}
Invoke-Checked "fetching pinned fixes_3_2 commit $SourceCommit" {
    & git -C $Source fetch --quiet --depth=1 origin $SourceCommit
}
Invoke-Checked 'checking out the pinned FPC source' {
    & git -C $Source checkout --quiet --detach FETCH_HEAD
}
$ActualCommit = "$( & git -C $Source rev-parse HEAD )".Trim()
if ($ActualCommit -cne $SourceCommit) {
    Fail "source pin mismatch: expected $SourceCommit, got $ActualCommit"
}

$MakeDestination = $Destination -replace '\\', '/'
$MakePp = $Pp -replace '\\', '/'
Push-Location $Source
try {
    Invoke-Checked "building native FPC 3.2.3 for $Target" {
        & $Make '-j2' "PP=$MakePp" 'OPT=-O2' all
    }
    Invoke-Checked "installing FPC 3.2.3 into $Destination" {
        & $Make "PP=$MakePp" "INSTALL_PREFIX=$MakeDestination" install
    }
}
finally {
    Pop-Location
}

$CompilerName = "$PpName$ExecutableSuffix"
$Compiler = Get-ChildItem -LiteralPath $Destination -Recurse -File `
    -Filter $CompilerName | Where-Object {
        $_.FullName -match '[/\\]lib[/\\]fpc[/\\]3\.2\.3[/\\]'
    } | Select-Object -First 1 -ExpandProperty FullName
if (-not $Compiler) {
    $Compiler = Get-ChildItem -LiteralPath $Destination -Recurse -File `
        -Filter $CompilerName | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Compiler) { Fail "installed compiler $CompilerName was not found" }

# Build a location-independent config from the actually installed unit tree.
# This avoids writing system-wide files and works with the native FPC driver on
# Windows, Linux and Darwin alike.
$ConfigDir = Join-Path $Destination 'etc'
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$ConfigPath = Join-Path $ConfigDir 'fpc.cfg'
$UnitDirs = Get-ChildItem -LiteralPath $Destination -Recurse -File -Filter '*.ppu' |
    ForEach-Object { $_.DirectoryName } | Sort-Object -Unique
if (-not $UnitDirs) { Fail 'the FPC install contains no compiled units' }
$LibraryDirs = Get-ChildItem -LiteralPath $Destination -Recurse -File |
    Where-Object { $_.Extension -in @('.a', '.o') } |
    ForEach-Object { $_.DirectoryName } | Sort-Object -Unique
$ConfigLines = @('# generated for the pinned FPC 3.2.3 CI toolchain')
$ConfigLines += $UnitDirs | ForEach-Object { "-Fu$_" }
$ConfigLines += $LibraryDirs | ForEach-Object { "-Fl$_" }
$ConfigLines | Set-Content -LiteralPath $ConfigPath -Encoding ascii

$ToolBin = Join-Path $Destination 'ci-bin'
New-Item -ItemType Directory -Force -Path $ToolBin | Out-Null
$Launcher = Join-Path $ToolBin "fpc$ExecutableSuffix"
if ($TargetOs -eq 'win64') {
    Copy-Item -LiteralPath $Compiler -Destination $Launcher -Force
}
else {
    New-Item -ItemType SymbolicLink -Path $Launcher -Target $Compiler -Force |
        Out-Null
}

$env:PPC_CONFIG_PATH = $ConfigDir
$Version = "$( & $Launcher -iV )".Trim()
$InstalledOs = "$( & $Launcher -iTO )".Trim().ToLowerInvariant()
$InstalledCpu = "$( & $Launcher -iTP )".Trim().ToLowerInvariant()
if ($Version -ne '3.2.3') {
    Fail "expected FPC 3.2.3 after the pinned build, got $Version"
}
if (($InstalledOs -ne $TargetOs) -or ($InstalledCpu -ne $TargetCpu)) {
    Fail "installed target mismatch: expected $Target, got $InstalledCpu-$InstalledOs"
}

if ($env:GITHUB_ENV) {
    "PPC_CONFIG_PATH=$ConfigDir" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
    "FPC_323_SOURCE_COMMIT=$SourceCommit" |
        Out-File -Append -Encoding utf8 $env:GITHUB_ENV
}
if ($env:GITHUB_PATH) {
    $ToolBin | Out-File -Append -Encoding utf8 $env:GITHUB_PATH
}

Write-Host "[fpc-3.2.3] installed $Version $InstalledCpu-$InstalledOs"
Write-Host "[fpc-3.2.3] source commit $ActualCommit"
Write-Host "[fpc-3.2.3] launcher $Launcher"
