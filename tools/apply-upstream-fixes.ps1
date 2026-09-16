param(
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Checkout = Join-Path $RepoRoot 'deps/mormot2'
$Patch = Join-Path $RepoRoot 'patches/mormot2-2026-09-16-abi-fixes.patch'
$LockFile = Join-Path $RepoRoot 'mormot.lock'

function Fail([string]$Message) {
    throw "[apply-upstream-fixes] $Message"
}

if (-not (Test-Path -LiteralPath (Join-Path $Checkout '.git'))) {
    Fail 'deps/mormot2 is missing; run tools/get-mormot.ps1 first'
}
if (-not (Test-Path -LiteralPath $Patch -PathType Leaf)) {
    Fail "patch is missing: $Patch"
}

$pinLine = Get-Content -LiteralPath $LockFile |
    Where-Object { $_ -match '^\s*commit\s*=' } |
    Select-Object -First 1
if (-not $pinLine) { Fail 'mormot.lock has no commit entry' }
$Pin = ($pinLine -split '=', 2)[1].Trim()
$Head = (git -C $Checkout rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { Fail 'unable to read dependency HEAD' }
if ($Head -cne $Pin) { Fail "dependency HEAD is $Head, expected $Pin" }

$dirty = @(git -C $Checkout status --porcelain |
    Where-Object { $_ -notmatch '\sstatic/' })
if ($LASTEXITCODE -ne 0) { Fail 'unable to inspect dependency status' }
if ($dirty.Count -ne 0) {
    # An already-applied exact patch is accepted; every other dirty state is
    # rejected so this helper never layers changes onto unknown source.
    git -C $Checkout apply --reverse --check --ignore-space-change `
        --whitespace=error-all $Patch
    if ($LASTEXITCODE -eq 0) {
        Write-Host '[apply-upstream-fixes] exact patch is already applied'
        exit 0
    }
    Fail ('dependency has unrelated changes: ' + ($dirty -join '; '))
}

git -C $Checkout apply --check --ignore-space-change `
    --whitespace=error-all $Patch
if ($LASTEXITCODE -ne 0) { Fail 'patch preflight failed against the pinned tree' }
if ($CheckOnly) {
    Write-Host '[apply-upstream-fixes] patch preflight PASS'
    exit 0
}

git -C $Checkout apply --ignore-space-change --whitespace=error-all $Patch
if ($LASTEXITCODE -ne 0) { Fail 'git apply failed' }

# Upstream stores these Pascal sources as CRLF. Keep every whitespace check
# enabled, but do not mistake the CR line terminator for trailing content.
git -c core.whitespace=cr-at-eol -C $Checkout diff --check
if ($LASTEXITCODE -ne 0) { Fail 'patched tree contains whitespace errors' }

$expected = @(
    'src/core/mormot.core.interfaces.pas',
    'src/lib/mormot.lib.quickjs.pas',
    'src/lib/mormot.lib.static.pas'
)
$actual = @(git -C $Checkout diff --name-only |
    Where-Object { $_ -notmatch '^static/' } |
    Sort-Object)
if ($LASTEXITCODE -ne 0) { Fail 'unable to list patched files' }
$wanted = @($expected | Sort-Object)
if (($actual.Count -ne $wanted.Count) -or
    (Compare-Object -ReferenceObject $wanted -DifferenceObject $actual)) {
    Fail "unexpected patch surface: $($actual -join ', ')"
}

Write-Host "[apply-upstream-fixes] applied to $Pin"
git -C $Checkout diff --stat
if ($LASTEXITCODE -ne 0) { Fail 'unable to print patch summary' }
