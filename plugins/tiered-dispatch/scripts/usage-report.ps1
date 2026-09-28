<#
  usage-report.ps1
  usage.jsonl을 읽어서 최근 N일 위임 현황을 한글 마크다운 보고서로 출력한다.
  가격/비용 추정은 하지 않는다.
#>

param(
    [int]$Days = 7,
    [string]$Project = "",
    [string]$DataDir = ""
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Format-Number {
    param([long]$Value)
    return $Value.ToString("N0")
}

# DataDir 결정: 파라미터 > CLAUDE_PLUGIN_DATA > $HOME\.claude\plugins\data\tiered-dispatch* 첫 매치
if ([string]::IsNullOrEmpty($DataDir)) {
    if (-not [string]::IsNullOrEmpty($env:CLAUDE_PLUGIN_DATA)) {
        $DataDir = $env:CLAUDE_PLUGIN_DATA
    } else {
        $candidateRoot = Join-Path $HOME ".claude\plugins\data"
        if (Test-Path -LiteralPath $candidateRoot) {
            $found = Get-ChildItem -LiteralPath $candidateRoot -Directory -Filter "tiered-dispatch*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $DataDir = $found.FullName }
        }
    }
}

if ([string]::IsNullOrEmpty($DataDir)) {
    Write-Output "데이터 디렉터리를 찾을 수 없습니다. CLAUDE_PLUGIN_DATA를 확인하세요."
    exit 0
}

$usagePath = Join-Path $DataDir "usage.jsonl"
if (-not (Test-Path -LiteralPath $usagePath)) {
    Write-Output "사용량 기록 파일이 없습니다: $usagePath"
    exit 0
}

$lines = Get-Content -LiteralPath $usagePath -Encoding UTF8
if (-not $lines -or $lines.Count -eq 0) {
    Write-Output "사용량 기록이 비어 있습니다."
    exit 0
}

$cutoff = (Get-Date).AddDays(-1 * $Days)

$records = New-Object System.Collections.Generic.List[object]
foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $entry = $null
    try {
        $entry = $line | ConvertFrom-Json
    } catch {
        continue
    }
    if ($null -eq $entry) { continue }

    $ts = $null
    try {
        $ts = [DateTimeOffset]::Parse($entry.ts)
    } catch {
        continue
    }
    if ($ts.LocalDateTime -lt $cutoff) { continue }

    if (-not [string]::IsNullOrEmpty($Project)) {
        $entryProject = "$($entry.project)"
        if ($entryProject.ToLowerInvariant().IndexOf($Project.ToLowerInvariant()) -lt 0) { continue }
    }

    $records.Add($entry)
}

if ($records.Count -eq 0) {
    Write-Output "조건에 맞는 사용량 기록이 없습니다 (기간: 최근 ${Days}일, 프로젝트: '$Project')."
    exit 0
}

$projectLabel = if ([string]::IsNullOrEmpty($Project)) { "전체" } else { $Project }

# 에이전트+모델별 그룹
$agentGroups = [ordered]@{}
foreach ($r in $records) {
    $modelsJoined = ""
    if ($r.models) {
        $modelsJoined = ($r.models -join ",")
    }
    $key = "$($r.agent_type)|$modelsJoined"
    if (-not $agentGroups.Contains($key)) {
        $agentGroups[$key] = [ordered]@{
            agent_type    = $r.agent_type
            models        = $modelsJoined
            count         = 0
            input_tokens  = 0
            cache_read    = 0
            output_tokens = 0
        }
    }
    $g = $agentGroups[$key]
    $g.count += 1
    $g.input_tokens += [long]$r.input_tokens
    $g.cache_read += [long]$r.cache_read_input_tokens
    $g.output_tokens += [long]$r.output_tokens
}

# 프로젝트별 그룹
$projectGroups = [ordered]@{}
foreach ($r in $records) {
    $key = "$($r.project)"
    if (-not $projectGroups.Contains($key)) {
        $projectGroups[$key] = [ordered]@{
            project      = $r.project
            count        = 0
            total_tokens = 0
        }
    }
    $g = $projectGroups[$key]
    $g.count += 1
    $g.total_tokens += ([long]$r.input_tokens + [long]$r.cache_creation_input_tokens + [long]$r.cache_read_input_tokens + [long]$r.output_tokens)
}

$totalDelegations = $records.Count

$output = New-Object System.Collections.Generic.List[string]
$output.Add("# 서브에이전트 위임 사용량 보고서")
$output.Add("")
$output.Add("- 기간: 최근 ${Days}일")
$output.Add("- 대상 프로젝트: $projectLabel")
$output.Add("- 총 위임 횟수: $(Format-Number $totalDelegations)")
$output.Add("")
$output.Add("## 에이전트/모델별 집계")
$output.Add("")
$output.Add("| 에이전트 | 모델 | 횟수 | 입력 토큰 | 캐시 읽기 | 출력 토큰 |")
$output.Add("|---|---|---|---|---|---|")

$totalCount = 0
$totalInput = 0
$totalCacheRead = 0
$totalOutput = 0

foreach ($key in $agentGroups.Keys) {
    $g = $agentGroups[$key]
    $output.Add("| $($g.agent_type) | $($g.models) | $(Format-Number $g.count) | $(Format-Number $g.input_tokens) | $(Format-Number $g.cache_read) | $(Format-Number $g.output_tokens) |")
    $totalCount += $g.count
    $totalInput += $g.input_tokens
    $totalCacheRead += $g.cache_read
    $totalOutput += $g.output_tokens
}
$output.Add("| **합계** |  | $(Format-Number $totalCount) | $(Format-Number $totalInput) | $(Format-Number $totalCacheRead) | $(Format-Number $totalOutput) |")
$output.Add("")
$output.Add("## 프로젝트별 집계")
$output.Add("")
$output.Add("| 프로젝트 | 횟수 | 총 토큰(입력+캐시생성+캐시읽기+출력) |")
$output.Add("|---|---|---|")

$totalProjectCount = 0
$totalProjectTokens = 0
foreach ($key in $projectGroups.Keys) {
    $g = $projectGroups[$key]
    $label = if ([string]::IsNullOrEmpty($g.project)) { "(알수없음)" } else { $g.project }
    $output.Add("| $label | $(Format-Number $g.count) | $(Format-Number $g.total_tokens) |")
    $totalProjectCount += $g.count
    $totalProjectTokens += $g.total_tokens
}
$output.Add("| **합계** | $(Format-Number $totalProjectCount) | $(Format-Number $totalProjectTokens) |")

Write-Output ($output -join "`n")
exit 0
