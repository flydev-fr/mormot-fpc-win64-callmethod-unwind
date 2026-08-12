# Assemble src/x64callmethod.asm and package the distributable object
# dist/x64callmethod.o (the .o naming follows mORMot's
# static/x86_64-win64/*.o convention; FPC's internal linker reads the
# file by content, the extension is irrelevant).
#
#   1. assemble with MASM ml64.exe;
#   2. strip the .debug$S section with llvm-objcopy -- ml64 records the
#      absolute build path there, and FPC's linker discards the section
#      anyway, so stripping makes the artifact path-independent;
#   3. validate the stripped COFF object (AMD64, non-empty
#      .text$mn/.pdata/.xdata, public x64callmethod, no .debug$S left,
#      no residual absolute-path strings);
#   4. print the deterministic section-content fingerprint of the
#      PRE-STRIP assembly output -- the SAME algorithm as
#      tools/prepare.ps1, so CI can compare it with the fingerprint
#      prepare.ps1 printed for the object it validated end-to-end.
#      (The post-strip file cannot be fingerprinted the same way:
#      removing .debug$S renumbers symbol-table indices, and .pdata
#      relocation entries embed those indices.  Step 3 therefore proves
#      the stripped file equivalent field by field instead: identical
#      section raw data, and identical relocations by offset, type and
#      resolved symbol NAME.)
#   5. write dist/x64callmethod.o.sha256 (whole-file hash; unlike the
#      fingerprint it varies with the assembler version, because the
#      symbol table embeds a toolset @comp.id).

[CmdletBinding()]
param(
    [string]$Ml64Path,
    [string]$ObjcopyPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AsmFile = Join-Path $RepoRoot 'src\x64callmethod.asm'
$DistDir = Join-Path $RepoRoot 'dist'
$OutFile = Join-Path $DistDir 'x64callmethod.o'
$ShaFile = "$OutFile.sha256"
$WorkDir = Join-Path $RepoRoot 'build\make-dist'

function Fail([string]$Message) {
    Write-Error "[make-dist] $Message" -ErrorAction Continue
    exit 1
}

function Read-CoffName([byte[]]$Bytes, [int]$Offset, [int]$Length) {
    $count = 0
    while (($count -lt $Length) -and ($Bytes[$Offset + $count] -ne 0)) {
        $count++
    }
    return [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $count)
}

# Keep in sync with tools/prepare.ps1: the fingerprint computed here MUST
# stay byte-identical to the one prepare.ps1 prints, because CI compares
# the two to tie the packaged artifact to the end-to-end validated object.
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
        SectionNames = @($requiredSections.Keys)
    }
}

function Get-CoffLayout([byte[]]$Bytes) {
    $sectionCount = [BitConverter]::ToUInt16($Bytes, 2)
    $symbolOffset = [BitConverter]::ToUInt32($Bytes, 8)
    $symbolCount = [BitConverter]::ToUInt32($Bytes, 12)
    $optionalSize = [BitConverter]::ToUInt16($Bytes, 16)
    $sectionOffset = 20 + $optionalSize
    $sections = @{}
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $offset = $sectionOffset + (40 * $i)
        $name = Read-CoffName $Bytes $offset 8
        $sections[$name] = [pscustomobject]@{
            RawSize = [BitConverter]::ToUInt32($Bytes, $offset + 16)
            RawOffset = [BitConverter]::ToUInt32($Bytes, $offset + 20)
            RelocationOffset = [BitConverter]::ToUInt32($Bytes, $offset + 24)
            RelocationCount = [BitConverter]::ToUInt16($Bytes, $offset + 32)
            Characteristics = [BitConverter]::ToUInt32($Bytes, $offset + 36)
        }
    }
    $symbolEnd = [uint64]$symbolOffset + ([uint64]18 * $symbolCount)
    $stringSize = [BitConverter]::ToUInt32($Bytes, [int]$symbolEnd)
    $symbolNames = @{}
    $index = 0
    while ($index -lt $symbolCount) {
        $offset = [int]$symbolOffset + (18 * $index)
        if ([BitConverter]::ToUInt32($Bytes, $offset) -eq 0) {
            $nameOffset = [BitConverter]::ToUInt32($Bytes, $offset + 4)
            $name = Read-CoffName $Bytes ([int]$symbolEnd + [int]$nameOffset) `
                ([int]$stringSize - [int]$nameOffset)
        }
        else {
            $name = Read-CoffName $Bytes $offset 8
        }
        $symbolNames[[uint32]$index] = $name
        $index += 1 + $Bytes[$offset + 17]
    }
    return [pscustomobject]@{
        Sections = $sections
        SymbolNames = $symbolNames
    }
}

# Stripping .debug$S renumbers symbol-table indices, so the stripped file
# cannot be compared to the assembly output byte for byte or through the
# prepare.ps1 fingerprint (relocation entries embed symbol indices).
# Prove semantic equivalence instead: for every retained section, the raw
# data, characteristics, and every relocation's offset, type and RESOLVED
# SYMBOL NAME must be identical.
function Assert-StrippedEquivalence([string]$OriginalPath, [string]$StrippedPath) {
    $originalBytes = [IO.File]::ReadAllBytes($OriginalPath)
    $strippedBytes = [IO.File]::ReadAllBytes($StrippedPath)
    $original = Get-CoffLayout $originalBytes
    $stripped = Get-CoffLayout $strippedBytes
    foreach ($name in @('.text$mn', '.pdata', '.xdata', '.data')) {
        $a = $original.Sections[$name]
        $b = $stripped.Sections[$name]
        if (($null -eq $a) -or ($null -eq $b)) {
            Fail "stripped object lost section $name"
        }
        if ($a.Characteristics -ne $b.Characteristics) {
            Fail "stripped object changed $name characteristics"
        }
        if ($a.RawSize -ne $b.RawSize) {
            Fail "stripped object changed $name size"
        }
        if (($a.RawSize -ne 0) -and
            ([Convert]::ToHexString($originalBytes, [int]$a.RawOffset, [int]$a.RawSize) -cne
             [Convert]::ToHexString($strippedBytes, [int]$b.RawOffset, [int]$b.RawSize))) {
            Fail "stripped object changed $name raw data"
        }
        if ($a.RelocationCount -ne $b.RelocationCount) {
            Fail "stripped object changed $name relocation count"
        }
        for ($i = 0; $i -lt $a.RelocationCount; $i++) {
            $ra = [int]$a.RelocationOffset + (10 * $i)
            $rb = [int]$b.RelocationOffset + (10 * $i)
            if ([BitConverter]::ToUInt32($originalBytes, $ra) -ne
                [BitConverter]::ToUInt32($strippedBytes, $rb)) {
                Fail "stripped object changed a $name relocation offset"
            }
            if ([BitConverter]::ToUInt16($originalBytes, $ra + 8) -ne
                [BitConverter]::ToUInt16($strippedBytes, $rb + 8)) {
                Fail "stripped object changed a $name relocation type"
            }
            $symbolA = $original.SymbolNames[[BitConverter]::ToUInt32($originalBytes, $ra + 4)]
            $symbolB = $stripped.SymbolNames[[BitConverter]::ToUInt32($strippedBytes, $rb + 4)]
            if (($null -eq $symbolA) -or ($symbolA -cne $symbolB)) {
                Fail "stripped object changed a $name relocation symbol"
            }
        }
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

function Resolve-Objcopy([string]$ExplicitPath) {
    if ($ExplicitPath) {
        $resolved = Resolve-Path -LiteralPath $ExplicitPath -ErrorAction SilentlyContinue
        if (($null -eq $resolved) -or -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
            Fail "explicit llvm-objcopy was not found: $ExplicitPath"
        }
        return $resolved.Path
    }
    $command = Get-Command llvm-objcopy.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installation = (& $vswhere -latest -products '*' `
            -property installationPath).Trim()
        if ($LASTEXITCODE -eq 0 -and $installation) {
            $candidates.Add((Join-Path $installation 'VC\Tools\Llvm\x64\bin\llvm-objcopy.exe'))
        }
    }
    $candidates.Add((Join-Path $env:ProgramFiles 'LLVM\bin\llvm-objcopy.exe'))
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    Fail 'llvm-objcopy not found; pass -ObjcopyPath (any LLVM distribution ships it)'
}

if (-not $IsWindows) { Fail 'packaging requires Windows' }
if (-not (Test-Path -LiteralPath $AsmFile -PathType Leaf)) {
    Fail "ASM source not found: $AsmFile"
}

$ml64 = Resolve-Ml64 $Ml64Path
$objcopy = Resolve-Objcopy $ObjcopyPath
Write-Host "[make-dist] ml64    : $ml64"
Write-Host "[make-dist] objcopy : $objcopy"

if (Test-Path -LiteralPath $WorkDir) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Force $WorkDir | Out-Null
New-Item -ItemType Directory -Force $DistDir | Out-Null

$tempObj = Join-Path $WorkDir 'x64callmethod.obj'
& $ml64 /nologo /c /Fo $tempObj $AsmFile
if (($LASTEXITCODE -ne 0) -or
    -not (Test-Path -LiteralPath $tempObj -PathType Leaf)) {
    Fail 'ml64 assembly failed'
}

& $objcopy --remove-section='.debug$S' $tempObj $OutFile
if (($LASTEXITCODE -ne 0) -or
    -not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
    Fail 'llvm-objcopy stripping failed'
}

# ml64 stamps the COFF header TimeDateStamp with the build time; zero it
# (reproducible-build convention, ignored by linkers) so the artifact is
# byte-identical across runs of the same toolset.
$outBytes = [IO.File]::ReadAllBytes($OutFile)
for ($i = 4; $i -lt 8; $i++) { $outBytes[$i] = 0 }
[IO.File]::WriteAllBytes($OutFile, $outBytes)

$unstripped = Assert-CoffObject $tempObj
$stripped = Assert-CoffObject $OutFile
if ($stripped.SectionNames -ccontains '.debug$S') {
    Fail 'stripped object still contains .debug$S'
}
Assert-StrippedEquivalence $tempObj $OutFile
$ascii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($OutFile))
if ($ascii -cmatch '[A-Za-z]:\\') {
    Fail 'stripped object still contains an absolute path string'
}

$hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($ShaFile, "$hash *x64callmethod.o`n")

Remove-Item -LiteralPath $WorkDir -Recurse -Force

Write-Host "[make-dist] output  : dist\x64callmethod.o ($($stripped.Size) bytes, .debug`$S stripped, sections/relocations proven identical)"
Write-Host "[make-dist] fingerprint=$($unstripped.Fingerprint)"
Write-Host "[make-dist] sha256  : $hash (dist\x64callmethod.o.sha256 written)"
Write-Host '[make-dist] READY'
