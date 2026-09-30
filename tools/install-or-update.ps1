<#
  install-or-update.ps1
  tiered-dispatch 플러그인 설치 겸 업데이트.
  - 처음 실행: (구버전 bat 설치본이 있으면 정리) → 이 폴더를 마켓플레이스로 등록 → 설치
  - 다시 실행: 새 파일을 받은 뒤 실행하면 최신 버전으로 업데이트
  - 폴더를 옮긴 경우: 마켓플레이스 경로를 새 위치로 다시 등록
  - 롤백: -SourceRoot <스냅샷 폴더> -Reinstall 로 이전 버전을 다시 설치 (rollback_to_2.4.bat)
  - 권장 설정(선택): 토큰 절감용 환경변수를 settings.json의 env에 추가 (-Reinstall이면 건너뜀)
  - -Yes: 모든 확인 질문에 y로 답한다 (테스트/자동화용)
#>
param(
    [string]$SourceRoot = "",
    [switch]$Reinstall,
    [switch]$Yes
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot    = Split-Path -Parent $PSScriptRoot
if (-not [string]::IsNullOrEmpty($SourceRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath($SourceRoot) }
$ToolsRoot   = Split-Path -Parent $PSScriptRoot
$ClaudeDir   = Join-Path $HOME ".claude"
$Migrate     = Join-Path $ToolsRoot "plugins\tiered-dispatch\scripts\migrate-legacy.ps1"
$Manifest    = Join-Path $RepoRoot "plugins\tiered-dispatch\.claude-plugin\plugin.json"
$ConfigDir   = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $ClaudeDir }
$SettingsPath  = Join-Path $ConfigDir "settings.json"
$EnvRecordPath = Join-Path $ConfigDir "tiered-dispatch-env.json"
$Marketplace = "team-claude"
$Plugin     = "tiered-dispatch@team-claude"

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
if ($Reinstall -and $installed -match [regex]::Escape($Plugin)) {
    # 버전을 내릴 때는 update가 적용되지 않을 수 있어 지우고 다시 설치한다.
    & claude plugin uninstall $Plugin
    & claude plugin install $Plugin
} elseif ($installed -match [regex]::Escape($Plugin)) {
    & claude plugin update $Plugin
} else {
    & claude plugin install $Plugin
}
# 꺼져 있던 경우(설정에서 비활성화 등) 다시 켠다.
if ((& claude plugin list 2>&1 | Out-String) -match "$([regex]::Escape($Plugin))[^\n]*(\n(?!\s*>)[^\n]*){0,5}?\n\s*Status:[^\n]*disabled") {
    & claude plugin enable $Plugin
}

Write-Host ""
& claude plugin list 2>&1 | Select-String -Context 0,3 "tiered-dispatch" | ForEach-Object { Write-Host $_ }

# ---- 4. 권장 설정 (선택) ----------------------------------------------------
Write-Step "4. 권장 설정 (선택)"
if ($Reinstall) {
    Write-Host "[SKIP] 롤백 설치에서는 권장 설정을 건너뜁니다."
} else {
    $recommendations = @(
        @{
            Key   = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
            Value = "200000"
            Desc  = "대화 컨텍스트가 200k 근처가 되면 자동 압축합니다(1M 컨텍스트 모델은 기본적으로 훨씬 크게 쌓임). 과거 기록 시뮬레이션에서 메인 비용 Opus 약 −40%, Sonnet 약 −57% (다시 읽기 비용 제외한 상한). 긴 세션에서는 앞 내용의 세부가 요약으로 바뀝니다."
        },
        @{
            Key   = "BASH_MAX_OUTPUT_LENGTH"
            Value = "15000"
            Desc  = "명령 출력이 15,000자를 넘으면 Claude Code가 잘라서 넣습니다(기본 30,000자). 긴 빌드·테스트 로그가 컨텍스트에 쌓이는 것을 줄입니다."
        }
    )

    $settings = Read-JsonFile $SettingsPath
    if ($null -eq $settings) {
        Write-Host "[SKIP] settings.json을 읽을 수 없어 건너뜁니다: $SettingsPath" -ForegroundColor Yellow
    } else {
        $currentEnv = $null
        if ($settings.PSObject.Properties["env"]) { $currentEnv = $settings.env }

        $added = [ordered]@{}
        foreach ($rec in $recommendations) {
            $key = $rec.Key
            if ($null -ne $currentEnv -and $currentEnv.PSObject.Properties[$key]) {
                Write-Host "[OK] $key 이미 settings.json에 설정되어 있음"
                continue
            }
            if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key, "Process")) -or
                -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key, "User"))) {
                Write-Host "[OK] $key 이미 환경변수로 설정되어 있음"
                continue
            }
            Write-Host ""
            Write-Host "$key = $($rec.Value)"
            Write-Host $rec.Desc
            if (Confirm-Step "이 설정을 추가할까요?") {
                $added[$key] = $rec.Value
            } else {
                Write-Host "[SKIP] $key 추가하지 않음"
            }
        }

        if ($added.Count -gt 0) {
            if (Test-Path -LiteralPath $SettingsPath) {
                $backup = "$SettingsPath.bak-tiered-dispatch-" + (Get-Date -Format "yyyyMMdd_HHmmss")
                Copy-Item -LiteralPath $SettingsPath -Destination $backup
                Write-Host "[BACKUP] $backup"
            }
            if ($null -eq $currentEnv) {
                $currentEnv = New-Object PSCustomObject
                if ($settings.PSObject.Properties["env"]) {
                    $settings.env = $currentEnv
                } else {
                    Add-Member -InputObject $settings -MemberType NoteProperty -Name "env" -Value $currentEnv
                }
            }
            foreach ($key in $added.Keys) {
                Add-Member -InputObject $currentEnv -MemberType NoteProperty -Name $key -Value $added[$key]
                Write-Host "[ADD] env.$key = $($added[$key])"
            }
            Write-JsonFile $SettingsPath $settings

            # 복원할 때 지울 수 있도록 추가한 키를 기록한다 (기존 기록과 합침).
            $record = [ordered]@{}
            $oldRecord = Read-JsonFile $EnvRecordPath
            if ($null -ne $oldRecord) {
                foreach ($prop in $oldRecord.PSObject.Properties) { $record[$prop.Name] = $prop.Value }
            }
            foreach ($key in $added.Keys) { $record[$key] = $added[$key] }
            Write-JsonFile $EnvRecordPath $record
            Write-Host "[OK] 설정 추가 완료: $SettingsPath"
        } else {
            Write-Host "[OK] 추가할 설정 없음"
        }
    }
}

Write-Step "완료"
Write-Host "Claude Code를 재시작하거나 새 대화를 시작하면 적용됩니다."
Write-Host "(이미 열려 있던 대화에는 적용되지 않습니다)"
