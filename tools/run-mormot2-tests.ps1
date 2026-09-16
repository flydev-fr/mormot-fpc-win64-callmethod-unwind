param(
    [string]$FpcPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Checkout = Join-Path $RepoRoot 'deps/mormot2'
$BuildRoot = if ([IO.Path]::DirectorySeparatorChar -eq '/') {
    # Several official network tests derive a Unix-domain socket name from
    # ProgramFilePath. GitHub's checkout path exceeds sockaddr_un.sun_path on
    # Linux, so use a deterministic short execution path without skipping the
    # socket tests.
    '/tmp/mormot2-regression'
}
else {
    Join-Path $RepoRoot 'build/mormot2-regression'
}

function Fail([string]$Message) {
    throw "[mormot2-regression] $Message"
}

function Resolve-Fpc([string]$ExplicitPath) {
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
        $candidates += @(
            'C:\fpc\3.2.3\bin\x86_64-win64\fpc.exe'
        )
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $version = (& $candidate -iV 2>$null | Select-Object -First 1)
        if ("$version".Trim() -eq '3.2.3') { return $candidate }
    }
    Fail 'FPC 3.2.3 was not found'
}

if (-not (Test-Path -LiteralPath (Join-Path $Checkout '.git'))) {
    Fail 'deps/mormot2 is missing; run tools/get-mormot.ps1 first'
}

$Fpc = Resolve-Fpc $FpcPath
$TargetOs = "$( & $Fpc -iTO )".Trim().ToLowerInvariant()
$TargetCpu = "$( & $Fpc -iTP )".Trim().ToLowerInvariant()
$Version = "$( & $Fpc -iV )".Trim()
$Target = "$TargetOs-$TargetCpu"
if ($TargetOs -notin @('win64', 'linux', 'darwin')) {
    Fail "unsupported CI target $Target"
}
Write-Host "[mormot2-regression] FPC $Version target $Target"

$UnitDir = Join-Path $BuildRoot "$Target-units"
$BinDir = Join-Path $BuildRoot "$Target-bin"
foreach ($dir in @($UnitDir, $BinDir)) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$extension = if ($TargetOs -eq 'win64') { '.exe' } else { '' }
$exe = Join-Path $BinDir "mormot2tests$extension"
$source = Join-Path (Join-Path $Checkout 'test') 'mormot2tests.dpr'
$src = Join-Path $Checkout 'src'

$args = @(
    '-MDelphi', '-Sci', '-Ci', '-O2', '-g', '-gl', '-gw2', '-Xg',
    '-dNO_UI'
)
if ($TargetOs -eq 'win64') {
    $args += @('-CX', '-XX', '-Xm')
}
elseif ($TargetOs -eq 'linux') {
    $args += @('-CX', '-XX')
}
elseif ($TargetOs -eq 'darwin') {
    $args += '-Cg-'
}

foreach ($relative in @('', 'core', 'net')) {
    $includeDir = if ($relative) { Join-Path $src $relative } else { $src }
    $args += "-Fi$includeDir"
}
foreach ($relative in @('app', 'core', 'crypt', 'db', 'lib', 'net', 'orm',
        'rest', 'soa', 'script', 'misc', 'tools/mget')) {
    $args += "-Fu$(Join-Path $src $relative)"
}
$staticDir = Join-Path (Join-Path $Checkout 'static') "$TargetCpu-$TargetOs"
if (-not (Test-Path -LiteralPath $staticDir -PathType Container)) {
    Fail "static library directory is missing: $staticDir"
}
$args += @(
    "-Fl$staticDir",
    "-FU$UnitDir", "-FE$BinDir", "-o$exe",
    '-B', '-Se10', $source
)

Write-Host "[mormot2-regression] compiling official test/mormot2tests.dpr"
$compileLines = @()
$compileCode = -1
# mormot2tests.dpr contains explicit relative `in '..\src\...'` and
# `in '.\test.*.pas'` clauses. FPC resolves those paths from its working
# directory, so compile from the upstream test directory just like the
# official build script is intended to be invoked.
Push-Location (Join-Path $Checkout 'test')
try {
    $compileLines = @(& $Fpc @args 2>&1 | ForEach-Object { "$_" })
    $compileCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
$compileLines | ForEach-Object { Write-Host $_ }
$compileLines | Set-Content -LiteralPath (Join-Path $BuildRoot "$Target-compile.log")
if ($compileCode -ne 0) {
    Fail "official regression suite did not compile on $Target (exit $compileCode)"
}
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    Fail "compiled regression executable is missing: $exe"
}

# Keep the official suite deterministic in CI: all regular Core/ORM/SOA tests
# run, while the only public-network probe (NTP) is disabled.
$runArgs = @()
if ($TargetOs -eq 'win64') {
    $runArgs += @('/noenter', '/nontp')
}
else {
    # Keep this as an actual one-element array. PowerShell otherwise unwraps
    # the single string returned by an if-expression and splats its characters.
    $runArgs += '--nontp'
}
New-Item -ItemType Directory -Force -Path (Join-Path $BinDir 'data') | Out-Null
Write-Host "[mormot2-regression] running $exe $($runArgs -join ' ')"
Push-Location $BinDir
try {
    $runLines = @(& $exe @runArgs 2>&1 | ForEach-Object { "$_" })
    $runCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
$runLines | ForEach-Object { Write-Host $_ }
$runLog = Join-Path $BuildRoot "$Target-run.log"
$runLines | Set-Content -LiteralPath $runLog
$runText = $runLines -join "`n"
if ($runCode -ne 0) {
    Fail "official regression suite failed on $Target (exit $runCode; see $runLog)"
}
if ($runText -notmatch '! All tests passed successfully\.') {
    Fail "official success marker is missing on $Target; see $runLog"
}

Write-Host "[mormot2-regression] full official suite PASS on $Target"
