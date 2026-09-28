<#
  install-or-update.ps1
  tiered-dispatch 플러그인 설치 겸 업데이트.
  - 처음 실행: (구버전 bat 설치본이 있으면 정리) → 이 폴더를 마켓플레이스로 등록 → 설치
  - 다시 실행: 새 파일을 받은 뒤 실행하면 최신 버전으로 업데이트
  - 폴더를 옮긴 경우: 마켓플레이스 경로를 새 위치로 다시 등록
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ClaudeDir   = Join-Path $HOME ".claude"
$Migrate     = Join-Path $RepoRoot "plugins\tiered-dispatch\scripts\migrate-legacy.ps1"
$Manifest    = Join-Path $RepoRoot "plugins\tiered-dispatch\.claude-plugin\plugin.json"
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

function Get-MarketplaceSource {
    # "claude plugin marketplace list" 출력에서 team-claude의 Source 줄을 찾는다.
    $lines = @(& claude plugin marketplace list 2>&1 | ForEach-Object { "$_" })
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch "^\s*>\s*$([regex]::Escape($Marketplace))\s*$") { continue }
        for ($j = $i + 1; $j -lt [Math]::Min($i + 4, $lines.Count); $j++) {
            if ($lines[$j] -match "Source:\s*Directory\s*\((.+)\)") { return $Matches[1].Trim() }
            if ($lines[$j] -match "Source:\s*(.+)$") { return $Matches[1].Trim() }
        }
        return ""
    }
    return $null
}

function Test-SamePath([string]$A, [string]$B) {
    $normA = [System.IO.Path]::GetFullPath($A).TrimEnd('\')
    $normB = [System.IO.Path]::GetFullPath($B).TrimEnd('\')
    return ($normA -ieq $normB)
}

# ---- 사전 확인 -------------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] claude 명령을 찾을 수 없습니다. Claude Code CLI 설치를 확인하세요." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Host "[ERROR] 플러그인 파일이 없습니다: $Manifest" -ForegroundColor Red
    Write-Host "        이 배치파일은 받은 폴더 안에서 실행해야 합니다."
    exit 1
}

$version = (Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json).version
Write-Host "플러그인 : tiered-dispatch v$version"
Write-Host "폴더     : $RepoRoot"
Write-Host "실행 중인 Claude Code 세션은 종료한 뒤 진행하는 것을 권장합니다."

# ---- 1. 구버전 정리 (해당하는 PC만) ----------------------------------------
Write-Step "1. 구버전 설치본 확인"
$preview = (& $Migrate -WhatIf *>&1 | Out-String)
if ($preview -match "\[DEL\]|\[EDIT\]") {
    Write-Host $preview
    if (Confirm-Step "예전 bat 설치본이 있습니다. 위 내용대로 정리할까요? (변경 전 파일은 백업됨)") {
        & $Migrate
    } else {
        Write-Host "[SKIP] 정리 건너뜀 - 예전 에이전트와 새 플러그인이 중복될 수 있습니다." -ForegroundColor Yellow
    }
} else {
    Write-Host "[OK] 정리할 구버전 설치본 없음"
}

# 직접 만든 simple-worker / handoff가 있으면 중복되므로 옮길지 묻는다.
$userItems = @(
    @{ Path = (Join-Path $ClaudeDir "agents\simple-worker.md"); Dest = "agents\simple-worker.md" },
    @{ Path = (Join-Path $ClaudeDir "skills\handoff");          Dest = "skills\handoff" }
)
foreach ($item in $userItems) {
    if (-not (Test-Path -LiteralPath $item.Path)) { continue }
    if (-not (Confirm-Step "$($item.Path) 가 플러그인과 중복됩니다. 백업 폴더로 옮길까요?")) {
        Write-Host "[KEEP] $($item.Path)"
        continue
    }
    $backupDir = Join-Path $ClaudeDir ("tiered-dispatch-migration-backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    $dest = Join-Path $backupDir $item.Dest
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Move-Item -LiteralPath $item.Path -Destination $dest
    Write-Host "[MOVE] $($item.Path) -> $dest"
}

# ---- 2. 마켓플레이스 등록/갱신 ---------------------------------------------
Write-Step "2. 마켓플레이스 등록"
$source = Get-MarketplaceSource
if ($null -eq $source) {
    & claude plugin marketplace add $RepoRoot
} elseif ($source -eq "" -or -not (Test-SamePath $source $RepoRoot)) {
    Write-Host "[INFO] 등록된 경로가 이 폴더와 다릅니다. ($source)"
    Write-Host "       이 폴더로 다시 등록합니다."
    & claude plugin marketplace remove $Marketplace
    & claude plugin marketplace add $RepoRoot
} else {
    & claude plugin marketplace update $Marketplace
}

# ---- 3. 설치 또는 업데이트 --------------------------------------------------
Write-Step "3. 플러그인 설치/업데이트"
$installed = (& claude plugin list 2>&1 | Out-String)
if ($installed -match [regex]::Escape($Plugin)) {
    & claude plugin update $Plugin
} else {
    & claude plugin install $Plugin
}

Write-Host ""
& claude plugin list 2>&1 | Select-String -Context 0,3 "tiered-dispatch" | ForEach-Object { Write-Host $_ }

Write-Step "완료"
Write-Host "Claude Code를 재시작하거나 새 대화를 시작하면 적용됩니다."
Write-Host "(이미 열려 있던 대화에는 적용되지 않습니다)"
