$ErrorActionPreference = "Stop"
$env:DEEPSEEK_API_KEY = 'REDACTED_API_KEY'

$root = $PSScriptRoot
$ws   = Join-Path $root "..\..\novel_workspace"

Write-Host "=== Auto Writer Engine ==="

$systemPrompt  = Get-Content (Join-Path $ws "scripts\system_prompt.txt") -Raw -Encoding UTF8
$directorNotes = Get-Content (Join-Path $ws "scripts\director_notes.txt") -Raw -Encoding UTF8
$chars         = Get-Content (Join-Path $ws "00_Knowledge\characters.md") -Raw -Encoding UTF8
$world         = Get-Content (Join-Path $ws "00_Knowledge\world_setting.md") -Raw -Encoding UTF8
$outline       = Get-Content (Join-Path $ws "00_Knowledge\main_outline.md") -Raw -Encoding UTF8
$state         = Get-Content (Join-Path $ws "01_State\current_status.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$chapter       = if ($state.current_chapter_to_write) { $state.current_chapter_to_write } else { $state.current_chapter }

Write-Host "Chapter: $chapter"

$nl = [Environment]::NewLine
$userPrompt = "## World Setting$nl$nl$world$nl$nl## Characters$nl$nl$chars$nl$nl## Outline$nl$nl$outline$nl$nl## Director Notes$nl$nl$directorNotes$nl$nlPlease write Chapter $chapter based on the above settings."

Write-Host "System: $($systemPrompt.Length) chars | User: $($userPrompt.Length) chars"

$payload = @{
    model       = "deepseek-chat"
    temperature = 0.7
    max_tokens  = 8192
    stream      = $false
    messages    = @(
        @{ role = "system"; content = $systemPrompt }
        @{ role = "user";   content = $userPrompt }
    )
}

$json = $payload | ConvertTo-Json -Depth 10 -Compress
$payloadPath = Join-Path $env:TEMP "deepseek_chapter_$chapter.json"
[System.IO.File]::WriteAllText($payloadPath, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host "Calling DeepSeek API (30-60s)..."
$response = Invoke-RestMethod -Uri "https://api.deepseek.com/chat/completions" `
    -Method Post `
    -ContentType "application/json; charset=utf-8" `
    -Headers @{ Authorization = "Bearer $env:DEEPSEEK_API_KEY" } `
    -InFile $payloadPath `
    -TimeoutSec 300

Remove-Item $payloadPath -ErrorAction SilentlyContinue
$content = $response.choices[0].message.content

if (-not $content -or $content.Length -lt 100) {
    Write-Host "ERROR: content too short ($($content.Length) chars)"
    exit 1
}

$chapterFile = Join-Path $ws "02_Drafts\chapter_0001.md"
[System.IO.File]::WriteAllText($chapterFile, $content, [System.Text.UTF8Encoding]::new($true))

Write-Host "OK: Chapter $chapter saved - $($content.Length) chars"
Write-Host "File: $chapterFile"

Push-Location $root\..\..
git add novel_workspace\02_Drafts\chapter_0001.md
git commit -m "feat: auto-generate chapter $chapter"
git push origin main
Pop-Location

Write-Host "=== Done ==="
