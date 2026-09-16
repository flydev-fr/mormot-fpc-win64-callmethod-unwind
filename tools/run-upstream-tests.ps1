param(
    [ValidateSet('Pristine', 'Patched')]
    [string]$Mode = 'Patched',
    [string]$FpcPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Checkout = Join-Path $RepoRoot 'deps/mormot2'
$BuildRoot = Join-Path $RepoRoot 'build/upstream-fixes'

function Fail([string]$Message) {
    throw "[upstream-tests/$Mode] $Message"
}

function Require-Literal([string]$Text, [string]$Needle, [string]$What) {
    if (-not $Text.Contains($Needle)) { Fail "missing $What" }
}

function Require-Match([string]$Text, [string]$Pattern, [string]$What) {
    if ($Text -notmatch $Pattern) { Fail "missing $What" }
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

function Read-Source([string]$RelativePath) {
    $path = Join-Path $Checkout ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Fail "source file is missing: $RelativePath"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Invoke-Compile([string]$Name, [string]$Source, [switch]$NoLink) {
    $ppu = Join-Path $BuildRoot "$($Mode.ToLowerInvariant())-$Name-ppu"
    $bin = Join-Path $BuildRoot "$($Mode.ToLowerInvariant())-$Name-bin"
    foreach ($dir in @($ppu, $bin)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $args = @(
        '-Sh', '-B', '-O1',
        "-Fi$(Join-Path $Checkout 'src')",
        "-FU$ppu", "-FE$bin"
    )
    foreach ($relative in @('', 'core', 'lib', 'crypt', 'net', 'db',
            'orm', 'rest', 'soa')) {
        $unitDir = if ($relative) {
            Join-Path (Join-Path $Checkout 'src') $relative
        }
        else {
            Join-Path $Checkout 'src'
        }
        $args += "-Fu$unitDir"
    }
    $staticDir = Join-Path (Join-Path $Checkout 'static') "$TargetCpu-$TargetOs"
    if (Test-Path -LiteralPath $staticDir -PathType Container) {
        $args += "-Fl$staticDir"
    }
    if ($TargetOs -eq 'win64') { $args += '-Xm' }
    if ($NoLink) { $args += '-Cn' }
    $args += $Source

    Write-Host "[upstream-tests/$Mode] $Fpc $($args -join ' ')"
    $lines = @(& $Fpc @args 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    $log = Join-Path $BuildRoot "$($Mode.ToLowerInvariant())-$Name-compile.log"
    $lines | Set-Content -LiteralPath $log
    return [pscustomobject]@{
        Code = $code
        Text = ($lines -join "`n")
        Bin = $bin
        Log = $log
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $Checkout '.git'))) {
    Fail 'deps/mormot2 is missing; run tools/get-mormot.ps1 first'
}
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

$Fpc = Resolve-Fpc $FpcPath
$TargetOs = "$( & $Fpc -iTO )".Trim().ToLowerInvariant()
$TargetCpu = "$( & $Fpc -iTP )".Trim().ToLowerInvariant()
$Version = "$( & $Fpc -iV )".Trim()
$Target = "$TargetOs-$TargetCpu"
Write-Host "[upstream-tests/$Mode] FPC $Version target $Target"

$core = Read-Source 'src/core/mormot.core.interfaces.pas'
$mac = Read-Source 'src/core/mormot.core.os.mac.pas'
$quick = Read-Source 'src/lib/mormot.lib.quickjs.pas'
$static = Read-Source 'src/lib/mormot.lib.static.pas'
$header = Read-Source 'res/static/libquickjs/quickjs.h'
$cutils = Read-Source 'res/static/libquickjs/cutils.h'

Require-Literal $header 'void JS_SetMaxStackSize(JSRuntime *rt, size_t stack_size);' `
    'QuickJS C runtime signature'
Require-Literal $cutils 'void *pas_malloc(size_t size);' 'C malloc size_t signature'
Require-Literal $cutils 'void *pas_realloc(void *ptr, size_t size);' `
    'C realloc size_t signature'
Require-Literal $cutils 'size_t pas_malloc_usable_size(void *ptr);' `
    'C malloc_usable_size size_t signature'

if ($Mode -eq 'Pristine') {
    Require-Literal $quick `
        'procedure JS_SetMaxStackSize(ctx: JSContext; stack_size: PtrUInt);' `
        'the pinned QuickJS mismatch'
    Require-Literal $static 'function pas_malloc(size: cardinal): pointer; cdecl;' `
        'the pinned 32-bit malloc size'
    Require-Literal $static `
        'function pas_malloc_usable_size(P: pointer): integer; cdecl;' `
        'the pinned signed malloc_usable_size result'
    Require-Literal $core 'cmp  x15, imvCurrency' `
        'the pinned AArch64 Currency/d0 branch'
    Require-Literal $mac `
        'kIOMasterPortDefault: mach_port_t; cvar; external;' `
        'the pinned address-based IOKit constant import'
    Require-Literal $mac `
        'CFSTR(id), kCFAllocatorDefault, 0);' `
        'the pinned address-based CoreFoundation allocator import'
    if ($core.Contains('FPC SysV x64 returns Currency through x87 ST0')) {
        Fail 'the pristine source unexpectedly contains the proposed x87 fix'
    }
}
else {
    Require-Literal $quick `
        'procedure JS_SetMaxStackSize(rt: JSRuntime; stack_size: PtrUInt);' `
        'corrected QuickJS runtime signature'
    Require-Match $static `
        'function\s+pas_malloc\(size:\s*PtrUInt\):\s*pointer;\s*cdecl;' `
        'PtrUInt pas_malloc signature'
    Require-Match $static `
        'function\s+pas_calloc\(n,\s*size:\s*PtrUInt\):\s*pointer;\s*cdecl;' `
        'PtrUInt pas_calloc signature'
    Require-Match $static `
        'function\s+pas_realloc\(P:\s*pointer;\s*Size:\s*PtrUInt\):\s*pointer;\s*cdecl;' `
        'PtrUInt pas_realloc signature'
    Require-Match $static `
        'function\s+pas_malloc_usable_size\(P:\s*pointer\):\s*PtrUInt;\s*cdecl;' `
        'PtrUInt malloc_usable_size result'
    Require-Literal $static `
        'if (n <> 0) and (size > PtrUInt(High(PtrInt)) div n) then' `
        'calloc multiplication overflow guard'
    Require-Match $quick `
        'function\s+pas_malloc\(size:\s*PtrUInt\):\s*pointer;\s*cdecl;' `
        'Delphi QuickJS PtrUInt allocator'
    Require-Match $quick `
        'function\s+pas_malloc_usable_size\(P:\s*pointer\):\s*PtrUInt;\s*cdecl;' `
        'Delphi QuickJS PtrUInt usable size'
    Require-Literal $core `
        'FPC SysV x64 returns Currency through x87 ST0, unlike Win64/RAX' `
        'SysV x64 Currency retrieval'
    Require-Literal $core `
        'AArch64 returns Currency as its scaled Int64 value in x0' `
        'AArch64 Currency retrieval'
    Require-Literal $mac `
        'kIOMasterPortDefault: mach_port_t = 0;' `
        'address-free IOKit default port constant'
    if ($mac.Contains('kIOMasterPortDefault: mach_port_t; cvar; external;')) {
        Fail 'the patched macOS source still imports kIOMasterPortDefault as a cvar'
    }
    Require-Literal $mac 'CFSTR(id), nil, 0);' `
        'address-free CoreFoundation default allocator value'
    if ($mac.Contains('kCFAllocatorDefault')) {
        Fail 'the patched macOS source still references kCFAllocatorDefault by address'
    }
}

Push-Location $RepoRoot
try {
    # mormot.lib.quickjs intentionally compiles as a void unit on Darwin, so
    # its public symbols cannot be type-checked there. The source assertions
    # above still gate the exact declaration on macOS; Windows and Linux run
    # the real compiler-level negative/positive differential.
    if ($TargetOs -eq 'darwin') {
        Write-Host "[upstream-tests/$Mode] QuickJS signature source gate PASS on Darwin"
    }
    else {
        $quickCompile = Invoke-Compile 'quickjs-signature' `
            'test/quickjs_signature_test.pas' -NoLink
        if ($Mode -eq 'Pristine') {
            if ($quickCompile.Code -eq 0) {
                Fail 'QuickJS mismatch was expected to fail compilation on pristine source'
            }
            if (($quickCompile.Text -notmatch 'JSRuntime') -or
                ($quickCompile.Text -notmatch 'JSContext')) {
                Fail "QuickJS compile failed for an unrelated reason; see $($quickCompile.Log)"
            }
            Write-Host '[upstream-tests/Pristine] QuickJS type mismatch CONFIRMED'
        }
        elseif ($quickCompile.Code -ne 0) {
            Fail "corrected QuickJS declaration did not compile; see $($quickCompile.Log)"
        }
    }

    if ($Mode -eq 'Patched') {
        $staticCompile = Invoke-Compile 'static-allocator' `
            'test/static_allocator_compile_test.pas' -NoLink
        if ($staticCompile.Code -ne 0) {
            Fail "corrected allocator unit did not compile; see $($staticCompile.Log)"
        }
    }

    $currencyCompile = Invoke-Compile 'currency-return' `
        'test/currency_return_test.pas'
    if ($currencyCompile.Code -ne 0) {
        if (($Mode -eq 'Pristine') -and ($TargetOs -eq 'darwin') -and
            ($currencyCompile.Text -match 'kIOMasterPortDefault') -and
            ($currencyCompile.Text -match 'does not have address')) {
            Write-Host ('[upstream-tests/Pristine] macOS IOKit absolute-symbol ' +
                "link defect CONFIRMED on $Target")
            return
        }
        Fail "Currency regression program did not compile; see $($currencyCompile.Log)"
    }
    $extension = if ($TargetOs -eq 'win64') { '.exe' } else { '' }
    $exe = Join-Path $currencyCompile.Bin ("currency_return_test$extension")
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Fail "Currency executable is missing: $exe"
    }
    $runtimeLines = @(& $exe 2>&1 | ForEach-Object { "$_" })
    $runtimeCode = $LASTEXITCODE
    $runtimeLines | ForEach-Object { Write-Host $_ }
    $runtimeText = $runtimeLines -join "`n"
    $resultMatch = [regex]::Match($runtimeText, 'CURRENCY-RESULT:\s*(\d+)/5')
    if (-not $resultMatch.Success) { Fail 'Currency result line is missing' }
    $passed = [int]$resultMatch.Groups[1].Value

    if ($Mode -eq 'Patched') {
        if (($runtimeCode -ne 0) -or ($passed -ne 5)) {
            Fail "patched Currency matrix failed on $Target ($passed/5, exit $runtimeCode)"
        }
    }
    elseif ($TargetOs -eq 'win64') {
        if (($runtimeCode -ne 0) -or ($passed -ne 5)) {
            Fail "the already-fixed Win64 baseline regressed ($passed/5, exit $runtimeCode)"
        }
    }
    else {
        if (($runtimeCode -eq 0) -or ($passed -ge 5)) {
            Fail "the pristine POSIX Currency defect did not reproduce on $Target"
        }
        Write-Host "[upstream-tests/Pristine] Currency defect CONFIRMED on $Target ($passed/5)"
    }
}
finally {
    Pop-Location
}

Write-Host "[upstream-tests/$Mode] PASS on $Target"
