<#
  restore.ps1
  tiered-dispatch 플러그인을 제거해 설치 전 상태로 되돌린다.
  - 플러그인 제거 → 마켓플레이스(team-claude) 등록 해제
  - 설치할 때 옮겨 둔 예전 파일(백업 폴더)이 있으면, 동의할 때만 제자리로 복원 (이미 있는 파일은 덮어쓰지 않음)
  - 사용량 기록(usage.jsonl)은 남긴다
  다시 적용하려면 install_or_update.bat을 실행한다.
  - 설치기가 추가한 권장 설정(settings.json의 env)이 있으면, 동의할 때만 값이 그대로인 키를 제거
  - -Yes: 모든 확인 질문에 y로 답한다 (테스트/자동화용)
#>
param(
    [switch]$Yes
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ClaudeDir   = Join-Path $HOME ".claude"
$ConfigDir   = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $ClaudeDir }
$SettingsPath  = Join-Path $ConfigDir "settings.json"
$EnvRecordPath = Join-Path $ConfigDir "tiered-dispatch-env.json"
$Marketplace = "team-claude"
$Plugin      = "tiered-dispatch@team-claude"

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Confirm-Step([string]$Question) {
    if ($Yes) {
        Write-Host "$Question (y/n): y"
        return $true
    }
    $answer = Read-Host "$Question (y/n)"
    return ($answer -eq "y" -or $answer -eq "Y")
}

# JSON 파일을 읽는다. 없거나 비어 있으면 빈 객체, 파싱 실패하면 $null.
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return (New-Object PSCustomObject) }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return (New-Object PSCustomObject) }
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# JSON 파일을 BOM 없는 UTF-8로 쓴다. (-InputObject: 배열이 풀리지 않게)
function Write-JsonFile([string]$Path, $Object) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $json = ConvertTo-Json -InputObject $Object -Depth 32
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
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

# ---- 4. 권장 설정 제거 (선택) -----------------------------------------------
Write-Step "4. 설치기가 추가한 권장 설정"
$record = $null
if (Test-Path -LiteralPath $EnvRecordPath) { $record = Read-JsonFile $EnvRecordPath }
if ($null -eq $record -or @($record.PSObject.Properties).Count -eq 0) {
    Write-Host "[OK] 제거할 권장 설정 기록 없음"
} else {
    $settings = Read-JsonFile $SettingsPath
    $currentEnv = $null
    if ($null -ne $settings -and $settings.PSObject.Properties["env"]) { $currentEnv = $settings.env }

    $toRemove = @()
    foreach ($prop in $record.PSObject.Properties) {
        $key = $prop.Name
        if ($null -eq $currentEnv -or -not $currentEnv.PSObject.Properties[$key]) {
            Write-Host "[OK] $key 이미 없음"
            continue
        }
        if ("$($currentEnv.$key)" -ne "$($prop.Value)") {
            Write-Host "[KEEP] $key 값이 설치 때와 달라 그대로 둡니다. (현재 $($currentEnv.$key), 설치 때 $($prop.Value))" -ForegroundColor Yellow
            continue
        }
        Write-Host "- $key = $($prop.Value)"
        $toRemove += $key
    }

    if ($toRemove.Count -gt 0) {
        if (Confirm-Step "위 설정을 settings.json의 env에서 제거할까요?") {
            $backup = "$SettingsPath.bak-tiered-dispatch-" + (Get-Date -Format "yyyyMMdd_HHmmss")
            Copy-Item -LiteralPath $SettingsPath -Destination $backup
            Write-Host "[BACKUP] $backup"
            foreach ($key in $toRemove) {
                $currentEnv.PSObject.Properties.Remove($key)
                Write-Host "[REMOVE] env.$key"
            }
            Write-JsonFile $SettingsPath $settings
            Remove-Item -LiteralPath $EnvRecordPath
        } else {
            Write-Host "[SKIP] 제거하지 않음 (기록 파일은 그대로 남음)"
        }
    } else {
        # 지울 것이 없으면 기록만 정리한다.
        Remove-Item -LiteralPath $EnvRecordPath
    }
}

Write-Step "완료"
Write-Host "Claude Code를 재시작하거나 새 대화를 시작하면 기본 상태로 동작합니다."
Write-Host "사용량 기록은 남아 있습니다: $ClaudeDir\plugins\data\tiered-dispatch-team-claude"
Write-Host "다시 적용하려면 install_or_update.bat을 실행하세요."
