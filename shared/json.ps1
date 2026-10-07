# Shared JSON/JSONC helpers, including atomic writes and backups.
function Get-Field {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Set-Field {
    param($Object, [string]$Name, $Value)
    if ($null -ne $Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function ConvertFrom-Jsonc {
    param([string]$Text)
    # A scanner preserves URLs, escaped quotes and comment-like text inside strings.
    $out = New-Object System.Text.StringBuilder
    $quoted = $false; $escaped = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($quoted) {
            [void]$out.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $quoted = $false }
            continue
        }
        if ($c -eq '"') { $quoted = $true; [void]$out.Append($c); continue }
        if ($c -eq '/' -and $i + 1 -lt $Text.Length) {
            if ($Text[$i + 1] -eq '/') {
                while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
                [void]$out.Append("`n"); continue
            }
            if ($Text[$i + 1] -eq '*') {
                $i += 2
                while ($i + 1 -lt $Text.Length -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
                if ($i + 1 -ge $Text.Length) { throw 'Unterminated JSONC comment.' }
                $i++; [void]$out.Append(' '); continue
            }
        }
        [void]$out.Append($c)
    }
    if ($quoted) { throw 'Unterminated JSON string.' }
    $clean = $out.ToString(); $out.Clear() | Out-Null
    $quoted = $false; $escaped = $false
    for ($i = 0; $i -lt $clean.Length; $i++) {
        $c = $clean[$i]
        if (-not $quoted -and $c -eq ',') {
            $j = $i + 1
            while ($j -lt $clean.Length -and [char]::IsWhiteSpace($clean[$j])) { $j++ }
            if ($j -lt $clean.Length -and $clean[$j] -in @('}', ']')) { continue }
        }
        [void]$out.Append($c)
        if ($quoted -and $escaped) { $escaped = $false }
        elseif ($quoted -and $c -eq '\') { $escaped = $true }
        elseif ($c -eq '"') { $quoted = -not $quoted }
    }
    return ($out.ToString() | ConvertFrom-Json)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    $raw = [IO.File]::ReadAllText($Path)
    if (-not $raw.Trim()) { return [pscustomobject]@{} }
    try { return ConvertFrom-Jsonc $raw } catch { throw "Invalid JSON in $Path : $($_.Exception.Message)" }
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($dir)
    $temporary = Join-Path $dir ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, ($Object | ConvertTo-Json -Depth 60), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, ($Path + '.bak'))
        } else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
