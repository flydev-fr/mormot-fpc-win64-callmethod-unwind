# Binary unwind gate: proves in the FINAL EXECUTABLE (not merely the OBJ)
# that the replacement trampoline carries valid Windows x64 unwind metadata:
#   - the OBJ is x64, exports public x64callmethod, has non-empty
#     .pdata/.xdata;
#   - the FPC internal-link map records exactly one READOBJECT provenance for
#     the replacement OBJ and retains its code/.pdata/.xdata contributions;
#   - dumpbin /unwindinfo shows a RUNTIME_FUNCTION entry that exactly covers
#     the mapped x64callmethod code range, whose unwind info lives inside the
#     OBJ's mapped .xdata, declares frame register RBP via SET_FPREG, and
#     records PUSH_NONVOL for both RBP and R12.
# Merely finding a PE exception directory is NOT accepted: the broken
# pristine executable has one too -- it just lacks an entry covering
# CallMethod.
#
# Usage: pwsh tools/check-unwind.ps1 -ObjectPath <obj> -ExecutablePath <exe>
#        -MapPath <map> [-DumpbinPath <dumpbin.exe>]

param(
    [Parameter(Mandatory = $true)]
    [string]$ObjectPath,
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [Parameter(Mandatory = $true)]
    [string]$MapPath,
    [string]$DumpbinPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    throw "[binary gate] $Message"
}

function Resolve-InputFile([string]$Path, [string]$Description) {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (($null -eq $resolved) -or
        -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        Fail "$Description not found: $Path"
    }
    return $resolved.Path
}

function Normalize-MapObjectPath([string]$Path) {
    $candidate = $Path.Trim().Trim('"')
    try {
        return [IO.Path]::GetFullPath($candidate)
    }
    catch {
        Fail "invalid object path in final link map: $Path"
    }
}

function Resolve-Dumpbin([string]$ExplicitPath) {
    if ($ExplicitPath) {
        return Resolve-InputFile $ExplicitPath 'dumpbin.exe'
    }
    $command = Get-Command dumpbin.exe -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    if ($env:VCToolsInstallDir) {
        $candidate = Join-Path $env:VCToolsInstallDir `
            'bin\Hostx64\x64\dumpbin.exe'
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
                ForEach-Object {
                    Join-Path $_.FullName 'bin\Hostx64\x64\dumpbin.exe'
                } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($candidate) { return $candidate }
        }
    }
    Fail 'dumpbin.exe not found; pass -DumpbinPath or initialize an MSVC x64 environment'
}

function Invoke-Dumpbin([string[]]$Arguments) {
    $output = & $script:Dumpbin @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Fail "dumpbin failed ($($Arguments -join ' ')):`n$output"
    }
    return $output
}

function Require-NonEmptyObjectSection([string]$Dump, [string]$Name) {
    $escaped = [regex]::Escape($Name)
    $match = [regex]::Match($Dump,
        "(?ims)^SECTION HEADER #\d+\s*`r?`n\s*$escaped name\s*`r?`n(?:(?!^SECTION HEADER).)*?^\s*([0-9A-F]+) size of raw data")
    if (-not $match.Success) { Fail "OBJ has no $Name section" }
    if ([Convert]::ToUInt64($match.Groups[1].Value, 16) -eq 0) {
        Fail "OBJ section $Name is empty"
    }
}

if (-not $IsWindows) { Fail 'binary gate requires Windows' }
if (([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
        [Runtime.InteropServices.Architecture]::X64) -or
    ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne
        [Runtime.InteropServices.Architecture]::X64)) {
    Fail 'binary gate requires a native Windows x64 process'
}

$object = Resolve-InputFile $ObjectPath 'COFF object'
$executable = Resolve-InputFile $ExecutablePath 'final executable'
$map = Resolve-InputFile $MapPath 'final link map'
$script:Dumpbin = Resolve-Dumpbin $DumpbinPath

$objectDump = Invoke-Dumpbin @('/headers', '/symbols', $object)
if ($objectDump -notmatch '(?im)^\s*8664 machine \(x64\)\s*$') {
    Fail 'OBJ machine is not x64 (8664)'
}
if ($objectDump -notmatch '(?im)^\s*[0-9A-F]+\s+[0-9A-F]+\s+SECT\d+\s+notype \(\)\s+External\s+\|\s+x64callmethod\s*$') {
    Fail 'OBJ has no public x64callmethod symbol'
}
Require-NonEmptyObjectSection $objectDump '.pdata'
Require-NonEmptyObjectSection $objectDump '.xdata'

$mapText = [IO.File]::ReadAllText($map)
$objectBaseName = [IO.Path]::GetFileName($object)
$objectName = [regex]::Escape($objectBaseName)
$readObjectEntries = @([regex]::Matches($mapText,
    '(?im)^READOBJECT\s+(.+?)\s*$') | ForEach-Object {
        [pscustomobject]@{
            Raw = $_.Groups[1].Value
            Normalized = Normalize-MapObjectPath $_.Groups[1].Value
        }
    })
$sameBaseReadObjects = @($readObjectEntries | Where-Object {
    [IO.Path]::GetFileName($_.Normalized) -ieq $objectBaseName
})
$exactReadObjects = @($sameBaseReadObjects | Where-Object {
    [string]::Equals($_.Normalized, $object,
        [StringComparison]::OrdinalIgnoreCase)
})
if (($sameBaseReadObjects.Count -ne 1) -or
    ($exactReadObjects.Count -ne 1)) {
    Fail "expected exactly one normalized READOBJECT provenance for '$object', found exact=$($exactReadObjects.Count), same-basename=$($sameBaseReadObjects.Count)"
}
$sameBaseLoads = @([regex]::Matches($mapText,
    '(?im)^LOAD\s+(.+?)\s*$') | Where-Object {
        [IO.Path]::GetFileName(
            (Normalize-MapObjectPath $_.Groups[1].Value)) -ieq $objectBaseName
    })
if ($sameBaseLoads.Count -ne 0) {
    Fail 'external-linker LOAD provenance is forbidden for x64callmethod.obj'
}

$codeSection = [regex]::Escape('.text$mn')
$code = [regex]::Match($mapText,
    "(?im)^\s*$codeSection\s+0x([0-9A-F]+)\s+0x([0-9A-F]+)\s+.*$objectName\s*$")
if (-not $code.Success) {
    Fail 'final link map has no x64callmethod.obj code contribution'
}
$symbol = [regex]::Match($mapText,
    '(?im)^\s*0x([0-9A-F]+)\s+x64callmethod\s*$')
if (-not $symbol.Success) { Fail 'final link map has no x64callmethod symbol' }
$startVa = [Convert]::ToUInt64($code.Groups[1].Value, 16)
$codeSize = [Convert]::ToUInt64($code.Groups[2].Value, 16)
$symbolVa = [Convert]::ToUInt64($symbol.Groups[1].Value, 16)
if (($codeSize -eq 0) -or ($symbolVa -ne $startVa)) {
    Fail 'mapped x64callmethod symbol does not start at its non-empty code contribution'
}
$sectionContributions = @{}
foreach ($sectionName in @('.pdata', '.xdata')) {
    $escapedSection = [regex]::Escape($sectionName)
    $section = [regex]::Match($mapText,
        "(?im)^\s*$escapedSection\s+0x([0-9A-F]+)\s+0x([0-9A-F]+)\s+.*$objectName\s*$")
    if ((-not $section.Success) -or
        ([Convert]::ToUInt64($section.Groups[2].Value, 16) -eq 0)) {
        Fail "final link map did not retain non-empty $sectionName from x64callmethod.obj"
    }
    $sectionContributions[$sectionName] = [pscustomobject]@{
        StartVa = [Convert]::ToUInt64($section.Groups[1].Value, 16)
        Size = [Convert]::ToUInt64($section.Groups[2].Value, 16)
    }
}

$headers = Invoke-Dumpbin @('/headers', $executable)
if ($headers -notmatch '(?im)^\s*8664 machine \(x64\)\s*$') {
    Fail 'final executable machine is not x64 (8664)'
}
$imageBaseMatch = [regex]::Match($headers,
    '(?im)^\s*([0-9A-F]+) image base(?:\s+\([^\r\n]+\))?\s*$')
if (-not $imageBaseMatch.Success) { Fail 'unable to read final PE image base' }
$imageBase = [Convert]::ToUInt64($imageBaseMatch.Groups[1].Value, 16)
if ($startVa -lt $imageBase) { Fail 'mapped code address precedes the PE image base' }
$startRva = $startVa - $imageBase
$endRva = $startRva + $codeSize

$unwind = Invoke-Dumpbin @('/unwindinfo', $executable)
$startHex = $startRva.ToString('X8')
$endHex = $endRva.ToString('X8')
$entryPattern = "(?im)^[ \t]*[0-9A-F]+[ \t]+$startHex[ \t]+$endHex[ \t]+([0-9A-F]+)[ \t\r]*$"
$entries = [regex]::Matches($unwind, $entryPattern)
if ($entries.Count -ne 1) {
    Fail "expected one exact RUNTIME_FUNCTION $startHex..$endHex, found $($entries.Count)"
}
$unwindRva = [Convert]::ToUInt64($entries[0].Groups[1].Value, 16)
if ($unwindRva -eq 0) { Fail 'x64callmethod RUNTIME_FUNCTION has zero unwind info' }
$xdata = $sectionContributions['.xdata']
if ($xdata.StartVa -lt $imageBase) {
    Fail 'mapped x64callmethod.obj .xdata precedes the PE image base'
}
$xdataStartRva = $xdata.StartVa - $imageBase
$xdataEndRva = $xdataStartRva + $xdata.Size
if (($unwindRva -lt $xdataStartRva) -or ($unwindRva -ge $xdataEndRva)) {
    Fail "x64callmethod unwind info RVA $($unwindRva.ToString('X8')) is outside mapped .xdata $($xdataStartRva.ToString('X8'))..$($xdataEndRva.ToString('X8'))"
}
$entryStart = $entries[0].Index
$entryLineEnd = $unwind.IndexOf("`n", $entryStart)
if ($entryLineEnd -lt 0) { Fail 'truncated dumpbin RUNTIME_FUNCTION entry' }
$tableEntryRegex = [regex]::new(
    '^[ \t]*[0-9A-F]{8}[ \t]+[0-9A-F]{8}[ \t]+[0-9A-F]{8}[ \t]+[0-9A-F]{8}[ \t\r]*$',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [Text.RegularExpressions.RegexOptions]::Multiline)
$nextEntry = $tableEntryRegex.Match($unwind, $entryLineEnd + 1)
if ($nextEntry.Success) {
    $entryText = $unwind.Substring($entryStart,
        $nextEntry.Index - $entryStart)
}
else {
    $entryText = $unwind.Substring($entryStart)
}
if ($entryText -notmatch '(?im)^\s*Unwind version:\s*[1-9][0-9]*\s*$') {
    Fail 'x64callmethod has no nonzero unwind version'
}
if ($entryText -notmatch '(?im)^\s*Frame register:\s*rbp\s*$') {
    Fail 'x64callmethod unwind frame register is not RBP'
}
if ($entryText -notmatch '(?im)SET_FPREG, register=rbp(?:, offset=0x0+)?\s*$') {
    Fail 'x64callmethod unwind codes do not establish RBP with SET_FPREG'
}
if ($entryText -notmatch '(?im)PUSH_NONVOL, register=rbp\s*$') {
    Fail 'x64callmethod unwind codes do not save RBP'
}
if ($entryText -notmatch '(?im)PUSH_NONVOL, register=r12\s*$') {
    Fail 'x64callmethod unwind codes do not save R12'
}

Write-Host "[binary gate] OBJ: x64 symbol + non-empty .pdata/.xdata"
Write-Host "[binary gate] map: exact READOBJECT '$($exactReadObjects[0].Normalized)', code=$($code.Groups[2].Value), retained .pdata/.xdata"
Write-Host "[binary gate] PE : exact RUNTIME_FUNCTION $startHex..$endHex, unwind RVA inside mapped .xdata, RBP SET_FPREG, saved RBP/R12"
Write-Host '[binary gate] PASS'
