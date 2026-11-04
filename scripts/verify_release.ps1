$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$hashFile = Join-Path $root "SHA256SUMS.txt"

if (-not (Test-Path -LiteralPath $hashFile)) {
    throw "SHA256SUMS.txt not found: $hashFile"
}

$failed = 0
$checked = 0

Get-Content -LiteralPath $hashFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line.Length -eq 0 -or $line.StartsWith("#")) {
        return
    }

    if ($line -notmatch '^([0-9A-Fa-f]{64})\s+\*?(.+)$') {
        throw "Invalid checksum line: $line"
    }

    $expected = $Matches[1].ToUpperInvariant()
    $relative = $Matches[2].Trim()
    $path = Join-Path $root $relative

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "[FAIL] missing  $relative"
        $failed++
        return
    }

    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $checked++
    if ($actual -eq $expected) {
        Write-Host "[ OK ] $relative"
    } else {
        Write-Host "[FAIL] $relative"
        Write-Host "       expected $expected"
        Write-Host "       actual   $actual"
        $failed++
    }
}

Write-Host ""
Write-Host "Checked: $checked file(s)"

if ($failed -ne 0) {
    Write-Host "Result: FAIL ($failed mismatch/missing)"
    exit 1
}

Write-Host "Result: PASS"
exit 0
