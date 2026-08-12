# Fetches the pinned mORMot2 commit into deps/mormot2 (git-ignored).
# The pin lives in mormot.lock at the repo root; this script never fetches
# a branch, a tag, or any floating ref -- only the exact SHA.
#
# The whole tree is pinned by the commit SHA and restored to a pristine
# state on every run (a dirty tree is force-restored, so run this only when
# you accept losing local modifications under deps/mormot2).
#
# Usage: pwsh tools/get-mormot.ps1 [-Force]

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LockFile = Join-Path $RepoRoot 'mormot.lock'
$DepsDir  = Join-Path $RepoRoot 'deps'
$Checkout = Join-Path $DepsDir 'mormot2'

# --- read the lock (strict: any malformed line is an error) -------------------
$Lock = @{}
$LineNo = 0
foreach ($line in Get-Content $LockFile) {
    $LineNo++
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '=') {
        throw "mormot.lock line ${LineNo}: malformed (expected 'key = value'): $line"
    }
    $k, $v = $line -split '=', 2
    $Lock[$k.Trim()] = $v.Trim()
}

$Url = $Lock['url']
$Sha = $Lock['commit']
if (-not $Url -or -not $Sha) { throw "mormot.lock: 'url' and 'commit' are required" }
if ($Sha -notmatch '^[0-9a-f]{40}$') { throw "mormot.lock: commit '$Sha' is not a full 40-char SHA" }

# --- fetch the exact SHA -----------------------------------------------------
if ((Test-Path $Checkout) -and $Force) { Remove-Item -Recurse -Force $Checkout }

if (-not (Test-Path (Join-Path $Checkout '.git'))) {
    New-Item -ItemType Directory -Force $Checkout | Out-Null
    git -C $Checkout init --quiet
    git -C $Checkout remote add origin $Url
}
else {
    # keep the remote in sync with the lock so a URL change is never ignored
    git -C $Checkout remote set-url origin $Url
    if ($LASTEXITCODE -ne 0) { throw 'git remote set-url failed' }
}

$Current = git -C $Checkout rev-parse --verify --quiet HEAD
if ($Current -ne $Sha) {
    # An existing checkout at an unexpected revision is not silently rebased:
    # fetching the pin and force-checking it out only ever happens on the
    # dedicated deps/mormot2 clone this script created. If HEAD is a foreign
    # commit that git does not know, the fetch below retrieves the pin; if the
    # directory is user work that should not be touched, it would carry
    # uncommitted changes and the pristine restore below aborts on -Force
    # being absent.
    if ($Current -and -not $Force) {
        $dirtyForeign = git -C $Checkout status --porcelain |
            Where-Object { $_ -notmatch '\sstatic/' }
        if ($dirtyForeign) {
            throw ("deps/mormot2 is at unexpected revision $Current with local " +
                'changes; refusing to modify it. Re-run with -Force to discard.')
        }
    }
    # Fetch only the pinned commit. No branch names, no tags, no HEAD.
    git -C $Checkout fetch --quiet --depth 1 origin $Sha
    if ($LASTEXITCODE -ne 0) { throw "git fetch of pinned SHA $Sha failed" }
    git -C $Checkout -c advice.detachedHead=false checkout --quiet --force $Sha
    if ($LASTEXITCODE -ne 0) { throw "git checkout of pinned SHA $Sha failed" }
}

# Even when HEAD already matches, restore a pristine tree whenever it is
# dirty: the whole tree feeds the test-suite compile. The static/ directory
# is NOT part of the git tree (release asset, installed below) and is
# excluded from the cleanup.
$Dirty = git -C $Checkout status --porcelain | Where-Object { $_ -notmatch '\sstatic/' }
if ($Dirty) {
    Write-Host 'deps/mormot2 tree is dirty -- restoring pristine pinned state'
    git -C $Checkout checkout --quiet --force $Sha
    if ($LASTEXITCODE -ne 0) { throw 'git checkout --force failed' }
    git -C $Checkout clean -qfdx -e static
    if ($LASTEXITCODE -ne 0) { throw 'git clean failed' }
    $Dirty = git -C $Checkout status --porcelain | Where-Object { $_ -notmatch '\sstatic/' }
    if ($Dirty) { throw 'deps/mormot2 tree still dirty after restore' }
}

$Head = git -C $Checkout rev-parse HEAD
if ($Head -ne $Sha) { throw "deps/mormot2 HEAD is $Head, expected pinned $Sha" }

# --- install the static .o/.a files (FPC requirement, sha256-pinned) ---------
$StaticsUrl = $Lock['statics-url']
$StaticsSha = $Lock['statics-sha256']
if (-not $StaticsUrl -or -not $StaticsSha) {
    throw "mormot.lock: 'statics-url' and 'statics-sha256' are required"
}
if ($StaticsSha -notmatch '^[0-9a-f]{64}$') {
    throw "mormot.lock: statics-sha256 is not a full sha256"
}

$StaticDir = Join-Path $Checkout 'static'
$Marker = Join-Path $StaticDir '.pinned-sha256'
if ((Test-Path $Marker) -and ((Get-Content $Marker -Raw).Trim() -eq $StaticsSha)) {
    Write-Host 'deps/mormot2/static already at pinned archive'
}
else {
    if (Test-Path $StaticDir) { Remove-Item -Recurse -Force $StaticDir }
    $Tgz = Join-Path $DepsDir 'mormot2static.tgz'
    Write-Host "downloading statics archive $StaticsUrl"
    Invoke-WebRequest -Uri $StaticsUrl -OutFile $Tgz
    $Got = (Get-FileHash -Algorithm SHA256 $Tgz).Hash.ToLowerInvariant()
    if ($Got -ne $StaticsSha) {
        Remove-Item -Force $Tgz
        throw "statics archive sha256 mismatch: got $Got, expected $StaticsSha"
    }
    New-Item -ItemType Directory -Force $StaticDir | Out-Null
    tar -xzf $Tgz -C $StaticDir
    if ($LASTEXITCODE -ne 0) { throw 'tar extraction of statics archive failed' }
    Remove-Item -Force $Tgz
    Set-Content -Path $Marker -Value $StaticsSha -NoNewline
    Write-Host 'deps/mormot2/static installed from pinned archive'
}

Write-Host "deps/mormot2 at pinned $Sha"
