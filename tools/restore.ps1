<#
  restore.ps1
  tiered-dispatch 플러그인을 제거해 설치 전 상태로 되돌린다.
  - 플러그인 제거 → 마켓플레이스(team-claude) 등록 해제
  - 설치할 때 옮겨 둔 예전 파일(백업 폴더)이 있으면, 동의할 때만 제자리로 복원 (이미 있는 파일은 덮어쓰지 않음)
  - 사용량 기록(usage.jsonl)은 남긴다
  다시 적용하려면 install_or_update.bat을 실행한다.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ClaudeDir   = Join-Path $HOME ".claude"
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

# ---- 사전 확인 -------------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] claude 명령을 찾을 수 없습니다. Claude Code CLI 설치를 확인하세요." -ForegroundColor Red
    exit 1
}

Write-Host "tiered-dispatch 플러그인을 제거하고 설치 전 상태로 되돌립니다."
Write-Host "실행 중인 Claude Code 세션은 종료한 뒤 진행하는 것을 권장합니다."
if (-not (Confirm-Step "진행할까요?")) {
    Write-Host "[SKIP] 취소했습니다."
    exit 0
}

# ---- 1. 플러그인 제거 -------------------------------------------------------
Write-Step "1. 플러그인 제거"
$installed = (& claude plugin list 2>&1 | Out-String)
if ($installed -match [regex]::Escape($Plugin)) {
    & claude plugin uninstall $Plugin
} else {
    Write-Host "[OK] 설치되어 있지 않음"
}

# ---- 2. 마켓플레이스 등록 해제 ----------------------------------------------
Write-Step "2. 마켓플레이스 등록 해제"
$markets = (& claude plugin marketplace list 2>&1 | Out-String)
if ($markets -match "(?m)^\s*>\s*$([regex]::Escape($Marketplace))\s*$") {
    & claude plugin marketplace remove $Marketplace
} else {
    Write-Host "[OK] 등록되어 있지 않음"
}

# ---- 3. 예전 파일 복원 (선택) -----------------------------------------------
Write-Step "3. 설치 때 옮겨 둔 예전 파일"
$backups = @(Get-ChildItem -LiteralPath $ClaudeDir -Directory -Filter "tiered-dispatch-migration-backup_*" -ErrorAction SilentlyContinue |
    Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0 } |
    Sort-Object Name)
if ($backups.Count -eq 0) {
    Write-Host "[OK] 백업 폴더 없음"
} else {
    foreach ($b in $backups) {
        Write-Host "- $($b.FullName)"
        Get-ChildItem -LiteralPath $b.FullName -Recurse -File | ForEach-Object {
            Write-Host ("    " + $_.FullName.Substring($b.FullName.Length).TrimStart("\"))
        }
    }
    Write-Host "예전 bat 방식의 에이전트·규칙 파일입니다. 보통은 복원하지 않아도 됩니다."
    if (Confirm-Step "위 파일을 ~/.claude 제자리로 복원할까요? (이미 있는 파일은 건너뜀)") {
        foreach ($b in $backups) {
            Get-ChildItem -LiteralPath $b.FullName -Recurse -File | ForEach-Object {
                $relative = $_.FullName.Substring($b.FullName.Length).TrimStart("\")
                $dest = Join-Path $ClaudeDir $relative
                if (Test-Path -LiteralPath $dest) {
                    Write-Host "[SKIP] 이미 있음: $dest" -ForegroundColor Yellow
                    return
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $dest
                Write-Host "[RESTORE] $dest"
            }
        }
        Write-Host "백업 폴더는 그대로 남겨 둡니다. 필요 없으면 직접 지우세요."
    } else {
        Write-Host "[SKIP] 복원하지 않음 (백업 폴더는 그대로 남음)"
    }
}

Write-Step "완료"
Write-Host "Claude Code를 재시작하거나 새 대화를 시작하면 기본 상태로 동작합니다."
Write-Host "사용량 기록은 남아 있습니다: $ClaudeDir\plugins\data\tiered-dispatch-team-claude"
Write-Host "다시 적용하려면 install_or_update.bat을 실행하세요."
