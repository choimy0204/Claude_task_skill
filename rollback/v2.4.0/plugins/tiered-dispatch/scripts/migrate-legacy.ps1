<#
  migrate-legacy.ps1
  구버전 .bat 설치기가 만든 파일들을 정리해서 새 tiered-dispatch 플러그인과 중복되지 않게 한다.
  기본적으로 $HOME\.claude 를 대상으로 하며, -WhatIf 로 드라이런 가능.
#>

param(
    [switch]$WhatIf,
    [string]$ClaudeDir = "$HOME\.claude"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$legacyDir = Join-Path $PSScriptRoot "legacy"

$deletedCount = 0
$editedCount = 0
$leftCount = 0

function Write-Action {
    param([string]$Tag, [string]$Message)
    $prefix = "[$Tag]"
    if ($WhatIf) { $prefix = "$prefix (WhatIf)" }
    Write-Output "$prefix $Message"
}

function Normalize-Content {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    # BOM 제거
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) {
        $Text = $Text.Substring(1)
    }
    # CRLF -> LF
    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r", "`n"
    # 라인별 trailing whitespace 제거
    $normLines = $Text -split "`n" | ForEach-Object { $_.TrimEnd() }
    $joined = ($normLines -join "`n").Trim()
    return $joined
}

function Get-LegacyNormalized {
    param([string]$FileName)
    $path = Join-Path $legacyDir $FileName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    return Normalize-Content -Text $raw
}

$legacyClaudeV1 = Get-LegacyNormalized "CLAUDE.v1.md"
$legacyClaudeV2 = Get-LegacyNormalized "CLAUDE.v2.md"
$legacyCodeSearcherV1 = Get-LegacyNormalized "code-searcher.v1.md"
$legacyCodeSearcherV2 = Get-LegacyNormalized "code-searcher.v2.md"
$legacyImplementerV1 = Get-LegacyNormalized "implementer.v1.md"
$legacyImplementerV2 = Get-LegacyNormalized "implementer.v2.md"

if (-not (Test-Path -LiteralPath $ClaudeDir)) {
    Write-Output "대상 디렉터리가 없습니다: $ClaudeDir"
    exit 0
}

# 백업 디렉터리 (WhatIf가 아닐 때만 생성)
$backupDir = Join-Path $ClaudeDir ("tiered-dispatch-migration-backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
if (-not $WhatIf) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

function Backup-File {
    param([string]$FullPath)
    if ($WhatIf) { return }
    $relative = $FullPath.Substring($ClaudeDir.Length).TrimStart("\", "/")
    $destPath = Join-Path $backupDir $relative
    $destDir = Split-Path -Path $destPath -Parent
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $FullPath -Destination $destPath -Force
}

# 1) agents\code-searcher.md, agents\implementer.md 처리
$agentTargets = @(
    @{ Path = Join-Path $ClaudeDir "agents\code-searcher.md"; Legacy = @($legacyCodeSearcherV1, $legacyCodeSearcherV2) },
    @{ Path = Join-Path $ClaudeDir "agents\implementer.md"; Legacy = @($legacyImplementerV1, $legacyImplementerV2) }
)

foreach ($target in $agentTargets) {
    $path = $target.Path
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $content = Normalize-Content -Text (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
    $isLegacyMatch = $false
    foreach ($legacyText in $target.Legacy) {
        if ($null -ne $legacyText -and $content -eq $legacyText) { $isLegacyMatch = $true; break }
    }

    if ($isLegacyMatch) {
        Backup-File -FullPath $path
        if (-not $WhatIf) { Remove-Item -LiteralPath $path -Force }
        Write-Action "DEL" "$path (구버전 설치 파일, 내용 동일)"
        $deletedCount++
    } else {
        Write-Action "WARN" "직접 수정된 파일이라 남겨둠: $path"
        $leftCount++
    }
}

# 2) agents\*.md.bak_* 처리
$bakFiles = @()
$agentsDir = Join-Path $ClaudeDir "agents"
if (Test-Path -LiteralPath $agentsDir) {
    $bakFiles = Get-ChildItem -LiteralPath $agentsDir -Filter "*.md.bak_*" -File -ErrorAction SilentlyContinue
}

foreach ($bak in $bakFiles) {
    $baseName = $bak.Name -replace "\.bak_.*$", ""
    $legacyCandidates = @()
    if ($baseName -match "code-searcher") {
        $legacyCandidates = @($legacyCodeSearcherV1, $legacyCodeSearcherV2)
    } elseif ($baseName -match "implementer") {
        $legacyCandidates = @($legacyImplementerV1, $legacyImplementerV2)
    }

    $content = Normalize-Content -Text (Get-Content -LiteralPath $bak.FullName -Raw -Encoding UTF8)
    $isLegacyMatch = $false
    foreach ($legacyText in $legacyCandidates) {
        if ($null -ne $legacyText -and $content -eq $legacyText) { $isLegacyMatch = $true; break }
    }

    if ($isLegacyMatch) {
        Backup-File -FullPath $bak.FullName
        if (-not $WhatIf) { Remove-Item -LiteralPath $bak.FullName -Force }
        Write-Action "DEL" "$($bak.FullName) (설치기가 만든 백업, 내용 동일)"
        $deletedCount++
    } else {
        Write-Action "INFO" "사용자의 설치 전 원본일 가능성이 있어 남겨둠 (직접 검토 권장): $($bak.FullName)"
        $leftCount++
    }
}

# 3) CLAUDE.md 처리
$claudeMdPath = Join-Path $ClaudeDir "CLAUDE.md"
if (Test-Path -LiteralPath $claudeMdPath) {
    $rawContent = Get-Content -LiteralPath $claudeMdPath -Raw -Encoding UTF8
    $normContent = Normalize-Content -Text $rawContent

    $wholeMatch = ($normContent -eq $legacyClaudeV1) -or ($normContent -eq $legacyClaudeV2)

    if ($wholeMatch) {
        Backup-File -FullPath $claudeMdPath
        if (-not $WhatIf) { Remove-Item -LiteralPath $claudeMdPath -Force }
        Write-Action "DEL" "$claudeMdPath (전체 내용이 구버전 CLAUDE.md와 동일)"
        $deletedCount++
    } else {
        $blockToRemove = $null
        if (-not [string]::IsNullOrEmpty($legacyClaudeV2) -and $normContent.Contains($legacyClaudeV2)) {
            $blockToRemove = $legacyClaudeV2
        } elseif (-not [string]::IsNullOrEmpty($legacyClaudeV1) -and $normContent.Contains($legacyClaudeV1)) {
            $blockToRemove = $legacyClaudeV1
        }

        if ($null -ne $blockToRemove) {
            Backup-File -FullPath $claudeMdPath

            $newContent = $normContent.Replace($blockToRemove, "")
            # 빈 줄 3개 이상 연속 -> 2개로 축소
            $newContent = $newContent -replace "(`n){3,}", "`n`n"
            $newContent = $newContent.Trim()

            if (-not $WhatIf) {
                # BOM 없이 UTF8로 저장
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($claudeMdPath, $newContent, $utf8NoBom)
            }
            Write-Action "EDIT" "$claudeMdPath (구버전 tiered-dispatch 블록 제거)"
            $editedCount++
        } else {
            Write-Action "INFO" "구버전 블록을 찾지 못해 남겨둠 (직접 검토 권장): $claudeMdPath"
            $leftCount++
        }
    }
}

# 4) simple-worker.md, skills\handoff 는 손대지 않고 안내만
$simpleWorkerPath = Join-Path $ClaudeDir "agents\simple-worker.md"
if (Test-Path -LiteralPath $simpleWorkerPath) {
    Write-Action "INFO" "새 플러그인의 simple-worker와 중복될 수 있음, 검토 후 수동 삭제 가능: $simpleWorkerPath"
}
$handoffPath = Join-Path $ClaudeDir "skills\handoff"
if (Test-Path -LiteralPath $handoffPath) {
    Write-Action "INFO" "새 플러그인의 handoff 스킬과 중복될 수 있음, 검토 후 수동 삭제 가능: $handoffPath"
}

# 백업 디렉터리가 비어 있으면 (WhatIf거나 아무 변경도 없으면) 정리
if (-not $WhatIf) {
    $backupHasFiles = $false
    if (Test-Path -LiteralPath $backupDir) {
        $backupHasFiles = @(Get-ChildItem -LiteralPath $backupDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0
    }
    if (-not $backupHasFiles -and (Test-Path -LiteralPath $backupDir)) {
        Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ""
Write-Output "=== 마이그레이션 요약 ==="
Write-Output "삭제: $deletedCount, 수정: $editedCount, 남김: $leftCount"
if (-not $WhatIf) {
    Write-Output "백업 위치: $backupDir"
}
Write-Output "Claude Code를 재시작하세요."

exit 0
