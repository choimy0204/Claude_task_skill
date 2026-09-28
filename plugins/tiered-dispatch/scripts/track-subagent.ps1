<#
  track-subagent.ps1
  Claude Code SubagentStop 훅. stdin으로 훅 JSON을 받아 서브에이전트 트랜스크립트에서
  모델별 토큰 사용량을 집계하고 usage.jsonl에 한 줄씩 append 한다.
  이 스크립트는 세션을 절대 중단시키지 않는다 (항상 exit 0).
#>

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # 콘솔 인코딩 설정 실패는 무시 (출력은 어차피 하지 않음)
}

function Write-TrackError {
    param([string]$Message)
    try {
        $dataDir = $env:CLAUDE_PLUGIN_DATA
        if ([string]::IsNullOrEmpty($dataDir)) { return }
        if (-not (Test-Path -LiteralPath $dataDir)) {
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        }
        $logPath = Join-Path $dataDir "track-errors.log"
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"), $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {
        # 에러 로그조차 못 쓰면 그냥 조용히 포기
    }
}

try {
    $dataDir = $env:CLAUDE_PLUGIN_DATA
    if ([string]::IsNullOrEmpty($dataDir)) {
        Write-TrackError "CLAUDE_PLUGIN_DATA 환경변수가 비어 있음"
        exit 0
    }
    if (-not (Test-Path -LiteralPath $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }

    $stdinRaw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($stdinRaw)) {
        Write-TrackError "stdin이 비어 있음"
        exit 0
    }

    $hook = $null
    try {
        $hook = $stdinRaw | ConvertFrom-Json
    } catch {
        Write-TrackError "훅 JSON 파싱 실패: $($_.Exception.Message)"
        exit 0
    }

    $sessionId = $hook.session_id
    $cwd = $hook.cwd
    $agentType = $hook.agent_type
    $agentId = $hook.agent_id
    $transcriptPath = $hook.agent_transcript_path

    $project = ""
    if (-not [string]::IsNullOrEmpty($cwd)) {
        $project = Split-Path -Path $cwd -Leaf
    }

    # 모델별 usage 집계용 상태
    $inputTokens = 0
    $outputTokens = 0
    $cacheCreationTokens = 0
    $cacheReadTokens = 0
    $models = New-Object System.Collections.Generic.List[string]
    $seenModels = @{}
    # message.id -> usage(마지막 값)로 중복 제거 (streamed chunk 대응)
    $usageById = New-Object System.Collections.Specialized.OrderedDictionary
    $modelById = @{}

    if (-not [string]::IsNullOrEmpty($transcriptPath) -and (Test-Path -LiteralPath $transcriptPath)) {
        $lines = Get-Content -LiteralPath $transcriptPath -Encoding UTF8
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $null
            try {
                $entry = $line | ConvertFrom-Json
            } catch {
                continue
            }
            if ($null -eq $entry.message) { continue }
            if ($null -eq $entry.message.usage) { continue }
            $msgId = $entry.message.id
            if ([string]::IsNullOrEmpty($msgId)) { continue }

            # 같은 id가 여러 줄에 나오면 마지막 것으로 덮어씀 (dedup)
            $usageById[$msgId] = $entry.message.usage
            $modelById[$msgId] = $entry.message.model
        }
    }

    foreach ($key in $usageById.Keys) {
        $usage = $usageById[$key]
        $model = $modelById[$key]

        if ($usage.input_tokens) { $inputTokens += [int]$usage.input_tokens }
        if ($usage.output_tokens) { $outputTokens += [int]$usage.output_tokens }
        if ($usage.cache_creation_input_tokens) { $cacheCreationTokens += [int]$usage.cache_creation_input_tokens }
        if ($usage.cache_read_input_tokens) { $cacheReadTokens += [int]$usage.cache_read_input_tokens }

        if (-not [string]::IsNullOrEmpty($model) -and -not $seenModels.ContainsKey($model)) {
            $seenModels[$model] = $true
            $models.Add($model)
        }
    }

    $turns = $usageById.Count

    $record = [ordered]@{
        ts                          = Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"
        session_id                  = $sessionId
        cwd                         = $cwd
        project                     = $project
        agent_type                  = $agentType
        agent_id                    = $agentId
        models                      = @($models.ToArray())
        turns                       = $turns
        input_tokens                = $inputTokens
        output_tokens               = $outputTokens
        cache_creation_input_tokens = $cacheCreationTokens
        cache_read_input_tokens     = $cacheReadTokens
    }

    $json = $record | ConvertTo-Json -Compress
    $usagePath = Join-Path $dataDir "usage.jsonl"
    Add-Content -LiteralPath $usagePath -Value $json -Encoding UTF8

    exit 0
} catch {
    Write-TrackError "예상치 못한 오류: $($_.Exception.Message)"
    exit 0
}
