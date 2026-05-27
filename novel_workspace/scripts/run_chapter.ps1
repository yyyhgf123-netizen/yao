$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$baseDir = $PSScriptRoot

$envContent = [System.IO.File]::ReadAllText("$baseDir\.env", $utf8NoBom)
$apiKey = ""
if ($envContent -match 'DEEPSEEK_API_KEY=(.+)') {
    $apiKey = $matches[1].Trim()
}

$systemPrompt = [System.IO.File]::ReadAllText("$baseDir\system_prompt.txt", $utf8NoBom)
$directorNotes = ""
$directorPath = "$baseDir\director_notes.txt"
if (Test-Path $directorPath) {
    $directorNotes = [System.IO.File]::ReadAllText($directorPath, $utf8NoBom)
}

$world = [System.IO.File]::ReadAllText("$baseDir\..\00_Knowledge\world_setting.md", $utf8NoBom)
$chars = [System.IO.File]::ReadAllText("$baseDir\..\00_Knowledge\characters.md", $utf8NoBom)
$outline = [System.IO.File]::ReadAllText("$baseDir\..\00_Knowledge\main_outline.md", $utf8NoBom)
$stateJson = [System.IO.File]::ReadAllText("$baseDir\..\01_State\current_status.json", $utf8NoBom)
$state = $stateJson | ConvertFrom-Json

$ch = $state.current_chapter
$name = $state.protagonist.name
$phys = $state.protagonist.physical_state
$loc = $state.protagonist.location

$recentLines = @()
foreach ($e in $state.recent_events) { $recentLines += "  - $e" }
$recentStr = $recentLines -join "`n"

$threadLines = @()
foreach ($t in $state.unresolved_threads) { $threadLines += "  - $t" }
$threadStr = $threadLines -join "`n"

$directorBlock = ""
if ($directorNotes -ne "") {
    $directorBlock = @"



$directorNotes
"@
}

$userPrompt = @"

$world


$chars


$outline


current_chapter: $ch
name: $name
physical_state: $phys
location: $loc
recent_events:
$recentStr
unresolved_threads:
$threadStr


$($stateJson)
$directorBlock
"@

$body = @{
    model = "deepseek-chat"
    messages = @(
        @{ role = "system"; content = $systemPrompt },
        @{ role = "user"; content = $userPrompt }
    )
    stream = $false
} | ConvertTo-Json -Depth 6

$headers = @{
    Authorization = "Bearer $apiKey"
    "Content-Type" = "application/json"
}

$wc = New-Object System.Net.WebClient
$wc.Encoding = $utf8NoBom
$wc.Headers.Add("Authorization", "Bearer $apiKey")
$wc.Headers.Add("Content-Type", "application/json")
$responseJson = $wc.UploadString("https://api.deepseek.com/v1/chat/completions", "POST", $body)
$responseObj = $responseJson | ConvertFrom-Json
$content = $responseObj.choices[0].message.content

$draftDir = "$baseDir\..\02_Drafts"
if (-not (Test-Path $draftDir)) { New-Item -ItemType Directory -Force -Path $draftDir | Out-Null }
$chapterNum = $ch.ToString("0000")
$outPath = "$draftDir\chapter_$chapterNum.md"
$content | Out-File -FilePath $outPath -Encoding utf8

Write-Host "Done: $outPath"
