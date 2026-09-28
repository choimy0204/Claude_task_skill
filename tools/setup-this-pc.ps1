<#
  setup-this-pc.ps1
  이 PC의 구버전(bat 설치본, 직접 만든 분배 설정)을 정리하고 tiered-dispatch 플러그인을 설치한다.
  단계마다 확인을 받는다. 지우거나 옮기는 파일은 모두 백업 폴더에 남긴다.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ClaudeDir   = Join-Path $HOME ".claude"
$Migrate     = Join-Path $RepoRoot "plugins\tiered-dispatch\scripts\migrate-legacy.ps1"
$Marketplace = "team-claude"
$Plugin      = "tiered-dispatch@team-claude"

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Confirm-Step([string]$Question) {
    $answer = Read-Host "$Question (y/n)"
    return ($answer -eq "y" -or $answer -eq "Y")
}

function Get-LatestBackupDir {
    $dir = Get-ChildItem -LiteralPath $ClaudeDir -Directory -Filter "tiered-dispatch-migration-backup_*" -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    if ($dir) { return $dir.FullName }

    $new = Join-Path $ClaudeDir ("tiered-dispatch-migration-backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    New-Item -ItemType Directory -Force -Path $new | Out-Null
    return $new
}

function Move-ToBackup([string]$Source, [string]$RelativeDest) {
    $backupDir = Get-LatestBackupDir
    $dest = Join-Path $backupDir $RelativeDest
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Move-Item -LiteralPath $Source -Destination $dest
    Write-Host "[MOVE] $Source -> $dest"
}

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] claude 명령을 찾을 수 없습니다. Claude Code CLI 설치를 확인하세요." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $Migrate)) {
    Write-Host "[ERROR] 정리 스크립트가 없습니다: $Migrate" -ForegroundColor Red
    exit 1
}

Write-Host "대상 폴더 : $ClaudeDir"
Write-Host "플러그인  : $RepoRoot"
Write-Host "실행 중인 Claude Code 세션은 모두 종료한 뒤 진행하는 것을 권장합니다."

# ---- 1. 구버전 bat 설치본 정리 -----------------------------------------
Write-Step "1. 구버전 설치본 정리 (미리보기)"
& $Migrate -WhatIf
if (Confirm-Step "위 내용대로 정리할까요?") {
    & $Migrate
} else {
    Write-Host "[SKIP] 1단계 건너뜀"
}

# ---- 2~3. 직접 만든 분배 설정 정리 ---------------------------------------
Write-Step "2. 직접 만든 분배 설정 정리"

$userItems = @(
    @{ Path = (Join-Path $ClaudeDir "agents\simple-worker.md"); Dest = "agents\simple-worker.md"; Label = "agents\simple-worker.md" },
    @{ Path = (Join-Path $ClaudeDir "skills\handoff");          Dest = "skills\handoff";          Label = "skills\handoff" }
)
foreach ($item in $userItems) {
    if (-not (Test-Path -LiteralPath $item.Path)) {
        Write-Host "[SKIP] $($item.Label) 없음"
        continue
    }
    if (Confirm-Step "$($item.Label) 을(를) 백업 폴더로 옮길까요? (플러그인에 같은 기능이 있음)") {
        Move-ToBackup $item.Path $item.Dest
    } else {
        Write-Host "[KEEP] $($item.Label)"
    }
}

$claudeMd = Join-Path $ClaudeDir "CLAUDE.md"
if (Test-Path -LiteralPath $claudeMd) {
    Write-Host ""
    Write-Host "---- 현재 $claudeMd 내용 ----" -ForegroundColor Yellow
    Get-Content -LiteralPath $claudeMd -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
    Write-Host "------------------------------" -ForegroundColor Yellow
    Write-Host "작업 분배 규칙 외에 다른 내용이 있다면 옮기지 말고, 나중에 해당 부분만 직접 지우세요."
    if (Confirm-Step "CLAUDE.md 전체를 백업 폴더로 옮길까요?") {
        Move-ToBackup $claudeMd "CLAUDE.md.user-rules"
    } else {
        Write-Host "[KEEP] CLAUDE.md"
    }
} else {
    Write-Host "[SKIP] CLAUDE.md 없음"
}

# ---- 4. 플러그인 설치 ----------------------------------------------------
Write-Step "3. tiered-dispatch 플러그인 설치"
if (-not (Confirm-Step "플러그인을 설치할까요?")) {
    Write-Host "[SKIP] 설치 건너뜀"
} else {
    $marketList = (& claude plugin marketplace list 2>&1) | Out-String
    if ($marketList -match [regex]::Escape($Marketplace)) {
        Write-Host "[SKIP] 마켓플레이스 $Marketplace 이미 등록됨 - 최신 내용으로 갱신"
        & claude plugin marketplace update $Marketplace
    } else {
        & claude plugin marketplace add $RepoRoot
    }

    $pluginList = (& claude plugin list 2>&1) | Out-String
    if ($pluginList -match [regex]::Escape($Plugin)) {
        Write-Host "[SKIP] $Plugin 이미 설치됨"
    } else {
        & claude plugin install $Plugin
    }

    Write-Host ""
    & claude plugin list
}

# ---- 마무리 --------------------------------------------------------------
Write-Step "완료"
$backup = Get-ChildItem -LiteralPath $ClaudeDir -Directory -Filter "tiered-dispatch-migration-backup_*" -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object -Last 1
if ($backup) {
    Write-Host "백업 위치: $($backup.FullName)"
    Write-Host "되돌리려면 백업 폴더의 파일을 원래 위치로 옮기세요. (CLAUDE.md.user-rules -> CLAUDE.md)"
}
Write-Host "Claude Code를 재시작하고, 새 세션에서 작업을 시작하세요."
