<#
  idle-notice.ps1
  Claude Code UserPromptSubmit 훅. 마지막 응답 뒤 프롬프트 캐시 수명(1시간 캐시면 60분, 5분 캐시면 30분 기준)이 지나 캐시가 만료됐고 컨텍스트가 크면,
  주제가 바뀐 경우에만 /clear를 권하도록 모델에 짧은 안내를 넣는다.
  또 세션 첫 응답의 컨텍스트(시스템 프롬프트·도구·플러그인·MCP 설명)가 크면 하루 한 번, 안 쓰는 플러그인·MCP를 끄라고 알리게 한다.
  조건이 아니면 아무것도 출력하지 않는다.
  이 스크립트는 세션을 절대 중단시키지 않는다 (항상 exit 0).
#>

# 구독 사용자는 메인 대화 캐시가 1시간(ephemeral_1h), API 키 사용자는 5분이다.
# 5분 캐시는 잠깐 쉴 때마다 알리면 시끄러우므로 30분을 기준으로 한다.
$GapMinutes1h = 60
$GapMinutes5m = 30
$MinCtx = 60000
# 첫 메인 응답의 컨텍스트가 이보다 크면 시작 컨텍스트가 크다고 본다.
$StartCtxLimit = 70000

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
}

# 파일의 앞 또는 끝에서 최대 $max 바이트를 읽어 줄 배열로 돌려준다.
function Read-Chunk($path, $max, $fromEnd) {
    $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = [Math]::Min($fs.Length, $max)
        if ($fromEnd) { [void]$fs.Seek(-$len, [System.IO.SeekOrigin]::End) }
        $bytes = New-Object byte[] $len
        [void]$fs.Read($bytes, 0, $len)
    } finally {
        $fs.Close()
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# 메인 응답 줄이면 컨텍스트 크기를, 아니면 -1을 돌려준다.
function Get-MainCtx($l) {
    if ($l -notlike '*"type":"assistant"*' -or $l -notlike '*"usage"*') { return -1 }
    try { $o = $l | ConvertFrom-Json } catch { return -1 }
    if ($o.isSidechain -or $o.message.model -eq '<synthetic>') { return -1 }
    if ($null -eq $o.message.usage) { return -1 }
    $u = $o.message.usage
    return [int64]$u.input_tokens + [int64]$u.cache_creation_input_tokens + [int64]$u.cache_read_input_tokens
}

try {
    # PS 5.1의 [Console]::In은 콘솔 코드페이지로 읽어 한글 경로가 깨지므로 바이트로 읽어 UTF-8로 디코딩한다.
    $stdinStream = [Console]::OpenStandardInput()
    $buffer = New-Object System.IO.MemoryStream
    $stdinStream.CopyTo($buffer)
    $hook = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray()) | ConvertFrom-Json
    $path = $hook.transcript_path
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path -LiteralPath $path)) { exit 0 }

    $notes = @()

    # 하루 한 번: 첫 메인 응답의 컨텍스트가 크면 플러그인·MCP 정리를 알리게 한다. 파일 앞 256KB만 본다.
    try {
        $dir = $env:CLAUDE_PLUGIN_DATA
        if ([string]::IsNullOrEmpty($dir)) { $dir = Join-Path $env:TEMP 'tiered-dispatch' }
        $flag = Join-Path $dir ('start-ctx-{0}.txt' -f (Get-Date -Format 'yyyyMMdd'))
        if (-not (Test-Path -LiteralPath $flag)) {
            foreach ($l in ((Read-Chunk $path 262144 $false) -split "`n")) {
                $first = Get-MainCtx $l
                if ($first -lt 0) { continue }
                if ($first -gt $StartCtxLimit) {
                    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    [System.IO.File]::WriteAllText($flag, [string]$first)
                    $fk = [int][Math]::Round($first / 1000)
                    $notes += "[tiered-dispatch] 이 세션은 첫 응답부터 컨텍스트가 $fk" + "k다(시스템 프롬프트·도구·플러그인·MCP 설명). 이 크기가 매 턴 다시 읽힌다. 답변 끝에 한 줄로 '이 작업에 쓰지 않는 플러그인·MCP 서버를 끄면 매 턴 비용이 줄어듭니다(/context로 확인)'라고 한 번만 알린다."
                }
                break
            }
        }
    } catch {
    }

    # 파일 끝 512KB만 읽어 마지막 메인 응답을 찾는다.
    $text = Read-Chunk $path 524288 $true
    $lines = $text -split "`n"
    $ctx = -1
    $timestamp = $null
    for ($i = $lines.Length - 1; $i -ge 0 -and $ctx -lt 0; $i--) {
        $c = Get-MainCtx $lines[$i]
        if ($c -lt 0) { continue }
        # ConvertFrom-Json이 날짜를 바꿔버리므로 원문에서 timestamp 문자열을 직접 뽑는다.
        if ($lines[$i] -notmatch '"timestamp"\s*:\s*"([^"]+)"') { continue }
        $timestamp = $Matches[1]
        $ctx = $c
    }

    if ($ctx -ge $MinCtx -and $null -ne $timestamp) {
        $last = [DateTimeOffset]::Parse($timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $gap = [int][Math]::Floor(([DateTimeOffset]::UtcNow - $last).TotalMinutes)
        # 최근 기록에 1시간 캐시 쓰기가 있으면 1시간 캐시로 본다.
        $gapLimit = $GapMinutes5m
        if ($text -match '"ephemeral_1h_input_tokens":\s*[1-9]') { $gapLimit = $GapMinutes1h }
        if ($gap -ge $gapLimit) {
            $k = [int][Math]::Round($ctx / 1000)
            $notes += "[tiered-dispatch] 마지막 응답 뒤 $gap" + "분이 지나 프롬프트 캐시가 만료됐다. 현재 컨텍스트 $k" + "k가 이번 턴에 다시 캐시에 쓰인다. 이번 요청이 앞 작업과 다른 주제면 답변 끝에 한 줄로 '다른 주제는 /clear 후 새 대화로 시작하면 비용이 줄어듭니다'라고 권한다. 같은 주제면 이 안내는 언급하지 않는다."
        }
    }
    if ($notes.Count -eq 0) { exit 0 }

    $msg = $notes -join ' '
    # 콘솔 인코딩과 무관하게 전달되도록 한글을 \u 이스케이프로 쓴다.
    $esc = -join ($msg.ToCharArray() | ForEach-Object { if ([int]$_ -gt 127) { '\u{0:x4}' -f [int]$_ } elseif ($_ -eq '"' -or $_ -eq '\') { '\' + $_ } else { $_ } })
    [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"' + $esc + '"}}')
} catch {
}
exit 0
