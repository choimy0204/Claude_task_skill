<#
  idle-notice.ps1
  Claude Code UserPromptSubmit 훅. 마지막 응답 뒤 30분 넘게 지나 프롬프트 캐시가 만료됐고 컨텍스트가 크면,
  주제가 바뀐 경우에만 /clear를 권하도록 모델에 짧은 안내를 넣는다. 조건이 아니면 아무것도 출력하지 않는다.
  이 스크립트는 세션을 절대 중단시키지 않는다 (항상 exit 0).
#>

$GapMinutes = 30
$MinCtx = 60000

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
}

try {
    # PS 5.1의 [Console]::In은 콘솔 코드페이지로 읽어 한글 경로가 깨지므로 바이트로 읽어 UTF-8로 디코딩한다.
    $stdinStream = [Console]::OpenStandardInput()
    $buffer = New-Object System.IO.MemoryStream
    $stdinStream.CopyTo($buffer)
    $hook = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray()) | ConvertFrom-Json
    $path = $hook.transcript_path
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path -LiteralPath $path)) { exit 0 }

    # 파일 끝 512KB만 읽어 마지막 메인 응답을 찾는다.
    $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = [Math]::Min($fs.Length, 524288)
        [void]$fs.Seek(-$len, [System.IO.SeekOrigin]::End)
        $bytes = New-Object byte[] $len
        [void]$fs.Read($bytes, 0, $len)
    } finally {
        $fs.Close()
    }
    $lines = [System.Text.Encoding]::UTF8.GetString($bytes) -split "`n"

    $ctx = -1
    $timestamp = $null
    for ($i = $lines.Length - 1; $i -ge 0 -and $ctx -lt 0; $i--) {
        $l = $lines[$i]
        if ($l -notlike '*"type":"assistant"*' -or $l -notlike '*"usage"*') { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        if ($o.isSidechain -or $o.message.model -eq '<synthetic>') { continue }
        if ($null -eq $o.message.usage) { continue }
        # ConvertFrom-Json이 날짜를 바꿔버리므로 원문에서 timestamp 문자열을 직접 뽑는다.
        if ($l -notmatch '"timestamp"\s*:\s*"([^"]+)"') { continue }
        $timestamp = $Matches[1]
        $u = $o.message.usage
        $ctx = [int64]$u.input_tokens + [int64]$u.cache_creation_input_tokens + [int64]$u.cache_read_input_tokens
    }
    if ($ctx -lt 0 -or $null -eq $timestamp) { exit 0 }
    if ($ctx -lt $MinCtx) { exit 0 }

    $last = [DateTimeOffset]::Parse($timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
    $gap = [int][Math]::Floor(([DateTimeOffset]::UtcNow - $last).TotalMinutes)
    if ($gap -lt $GapMinutes) { exit 0 }

    $k = [int][Math]::Round($ctx / 1000)
    $msg = "[tiered-dispatch] 마지막 응답 뒤 $gap" + "분이 지나 프롬프트 캐시가 만료됐다. 현재 컨텍스트 $k" + "k가 이번 턴에 다시 캐시에 쓰인다. 이번 요청이 앞 작업과 다른 주제면 답변 끝에 한 줄로 '다른 주제는 /clear 후 새 대화로 시작하면 비용이 줄어듭니다'라고 권한다. 같은 주제면 이 안내는 언급하지 않는다."
    # 콘솔 인코딩과 무관하게 전달되도록 한글을 \u 이스케이프로 쓴다.
    $esc = -join ($msg.ToCharArray() | ForEach-Object { if ([int]$_ -gt 127) { '\u{0:x4}' -f [int]$_ } elseif ($_ -eq '"' -or $_ -eq '\') { '\' + $_ } else { $_ } })
    [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"' + $esc + '"}}')
} catch {
}
exit 0
