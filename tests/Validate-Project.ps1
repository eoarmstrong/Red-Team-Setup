# Read-only checks before publishing the oscp-setup project.
# Run from any directory: powershell -NoProfile -File tests/Validate-Project.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path $projectRoot 'oscp-setup.sh'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Add-Failure([string]$message) {
    [void]$failures.Add($message)
    Write-Host "FAIL  $message" -ForegroundColor Red
}

function Add-Pass([string]$message) {
    Write-Host "PASS  $message" -ForegroundColor Green
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    Add-Failure 'oscp-setup.sh is missing.'
    exit 1
}

# The repository should contain source and documentation, not recordings or loot.
$allowedExtensions = @('.sh', '.ps1', '.md', '.json', '.yml', '.yaml')
$allowedNames = @('LICENSE', '.gitignore', '.gitattributes', '.editorconfig')
$pending = New-Object 'System.Collections.Generic.Stack[string]'
$files = New-Object 'System.Collections.Generic.List[IO.FileInfo]'
$pending.Push($projectRoot)
while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    foreach ($item in (Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
        if ($item.Name -eq '.git' -and $item.PSIsContainer) { continue }
        $relative = $item.FullName.Substring($projectRoot.Length).TrimStart('\', '/')
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-Failure "Linked path in project: $relative"
            continue
        }
        if ($item.PSIsContainer) {
            $pending.Push($item.FullName)
        } else {
            $files.Add($item)
            if ($item.Extension -notin $allowedExtensions -and $item.Name -notin $allowedNames) {
                Add-Failure "Unexpected file type: $relative"
            }
        }
    }
}
if ($files.Count -gt 0) { Add-Pass "Inspected $($files.Count) project files." }

$sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
$hasBom = $sourceBytes.Length -ge 3 -and $sourceBytes[0] -eq 239 -and $sourceBytes[1] -eq 187 -and $sourceBytes[2] -eq 191
if ($hasBom) { Add-Failure 'oscp-setup.sh has a UTF-8 BOM.' }
elseif ([Text.Encoding]::UTF8.GetString($sourceBytes) -notmatch '^#!/usr/bin/env bash\n') {
    Add-Failure 'oscp-setup.sh does not begin with the expected Bash shebang and LF newline.'
} else { Add-Pass 'Bash shebang and no UTF-8 BOM.' }

$crlf = [byte[]](13, 10)
$hasCrLf = $false
for ($i = 0; $i -lt $sourceBytes.Length - 1; $i++) {
    if ($sourceBytes[$i] -eq $crlf[0] -and $sourceBytes[$i + 1] -eq $crlf[1]) {
        $hasCrLf = $true
        break
    }
}
if ($hasCrLf) { Add-Failure 'oscp-setup.sh contains CRLF line endings.' }
else { Add-Pass 'Bash source uses LF line endings.' }

$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$source = $null
try { $source = $utf8.GetString($sourceBytes) }
catch { Add-Failure 'oscp-setup.sh is not valid UTF-8.' }

if ($null -ne $source) {
    foreach ($name in @('setup', 'logme', 'scanme', 'scriptme')) {
        if ($source -notmatch "(?m)^\s*$name\(\)\s*\{") {
            Add-Failure "Missing workflow entrypoint: $name"
        }
    }

    $tabs = [ordered]@{
        Scanning_1 = 'scan'; Scanning_2 = 'scan'
        Working_1 = 'log'; Working_2 = 'log'
        Target = 'idle'; HTTP_Server = 'http'
        NC_1 = 'idle'; NC_2 = 'idle'
        Ligolo = 'log'; Wireshark = 'log'; Responder = 'log'
    }
    foreach ($tab in $tabs.Keys) {
        $expected = [regex]::Escape("${tab}:$($tabs[$tab])")
        if ($source -notmatch "(?<![A-Za-z0-9_])$expected(?![A-Za-z0-9_])") {
            Add-Failure "Missing QTerminal tab assignment: $tab"
        }
    }
    Add-Pass 'Checked logging commands and QTerminal tab assignments.'
}

# Scan the files that would be published. Report location only; never echo a secret.
$findingsBeforeScan = $failures.Count
foreach ($file in $files) {
    $relative = $file.FullName.Substring($projectRoot.Length).TrimStart('\', '/')
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
        Add-Failure "Binary content in source file: $relative"
        continue
    }
    try { $content = $utf8.GetString($bytes) }
    catch {
        Add-Failure "Non-UTF-8 source file: $relative"
        continue
    }

    foreach ($match in [regex]::Matches($content, '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')) {
        $parts = $match.Value.Split('.')
        $octets = @($parts | ForEach-Object { [int]$_ })
        if (@($octets | Where-Object { $_ -gt 255 }).Count -gt 0) { continue }
        $documentation = ($octets[0] -eq 192 -and $octets[1] -eq 0 -and $octets[2] -eq 2) -or
                         ($octets[0] -eq 198 -and $octets[1] -eq 51 -and $octets[2] -eq 100) -or
                         ($octets[0] -eq 203 -and $octets[1] -eq 0 -and $octets[2] -eq 113)
        $localOnly = $octets[0] -eq 127 -or $match.Value -eq '0.0.0.0'
        if (-not $documentation -and -not $localOnly) {
            $line = 1 + [regex]::Matches($content.Substring(0, $match.Index), "`n").Count
            Add-Failure "Non-documentation IPv4 address in ${relative}:$line"
        }
    }

    $privateKey = '(?i)-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'
    $credentialAssignment = '(?im)^\s*(?:export\s+)?[\x27\x22]?[A-Za-z_][A-Za-z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY)[A-Za-z0-9_]*[\x27\x22]?\s*[:=]\s*[\x27\x22]?([^\s\x27\x22#},]+)'
    $tokenPattern = '(?i)\b(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,})\b'
    if ([regex]::IsMatch($content, $privateKey) -or [regex]::IsMatch($content, $tokenPattern)) {
        Add-Failure "Possible private key or access token in $relative"
    }
    foreach ($match in [regex]::Matches($content, $credentialAssignment)) {
        $value = $match.Groups[1].Value
        if ($value -notmatch '^(?:\$|<|YOUR_|EXAMPLE_|REPLACE_|CHANGEME|REDACTED|\*+)' ) {
            $line = 1 + [regex]::Matches($content.Substring(0, $match.Index), "`n").Count
            Add-Failure "Possible credential assignment in ${relative}:$line"
        }
    }
}
if ($failures.Count -eq $findingsBeforeScan) {
    Add-Pass 'No obvious personal IPs or credentials in project text.'
}

# Syntax-check when Git Bash or another working Bash is installed locally.
$bash = Get-Command bash -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
if ($null -eq $bash -and $env:ProgramFiles) {
    $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if (Test-Path -LiteralPath $gitBash -PathType Leaf) { $bash = Get-Item -LiteralPath $gitBash }
}
if ($null -ne $bash) {
    $bashPath = if ($bash.PSObject.Properties['Source']) { $bash.Source } else { $bash.FullName }
    & $bashPath --version *> $null
    if ($LASTEXITCODE -eq 0) {
        & $bashPath -n $sourcePath
        if ($LASTEXITCODE -eq 0) { Add-Pass 'bash -n syntax check.' }
        else { Add-Failure 'bash -n syntax check failed.' }
    } else {
        Write-Host 'SKIP  Bash command is present but does not run.' -ForegroundColor Yellow
    }
} else {
    Write-Host 'SKIP  Bash is not installed; run bash -n oscp-setup.sh on Kali.' -ForegroundColor Yellow
}

if ($failures.Count -gt 0) {
    Write-Host "Validation failed: $($failures.Count) issue(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'Validation passed.' -ForegroundColor Green
