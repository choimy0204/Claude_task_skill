<#
  suggest-clear.ps1
  Claude Code Stop 훅. 응답이 끝날 때 메인 컨텍스트 크기를 보고, 커졌으면 /clear·/compact 권장 문구를 사용자에게 띄운다.
  모델에는 아무것도 넣지 않는다(토큰 0). 문구는 120k를 넘을 때 한 번, 이후 100k 늘 때마다 한 번.
  실측 근거: 과거 기록에서 주제가 바뀐 뒤에도 이전 컨텍스트를 계속 읽은 비용이 전체의 약 17~24%.
  이 스크립트는 세션을 절대 중단시키지 않는다 (항상 exit 0).
#>

$FirstAt = 120000
$Step = 100000

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

    # 파일 끝 512KB만 읽어 마지막 메인 응답의 usage를 찾는다.
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
    for ($i = $lines.Length - 1; $i -ge 0 -and $ctx -lt 0; $i--) {
        $l = $lines[$i]
        if ($l -notlike '*"type":"assistant"*' -or $l -notlike '*"usage"*') { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        if ($o.isSidechain -or $o.message.model -eq '<synthetic>') { continue }
        $u = $o.message.usage
        $ctx = [int64]$u.input_tokens + [int64]$u.cache_creation_input_tokens + [int64]$u.cache_read_input_tokens
    }
    if ($ctx -lt 0) { exit 0 }

    $level = 0
    if ($ctx -ge $FirstAt) { $level = [int][Math]::Floor(($ctx - $FirstAt) / $Step) + 1 }

    # 세션별로 마지막으로 알린 단계를 기록한다. /compact로 줄면 단계도 낮춰 다시 넘을 때 알린다.
    $dir = $env:CLAUDE_PLUGIN_DATA
    if ([string]::IsNullOrEmpty($dir)) { $dir = Join-Path $env:TEMP 'tiered-dispatch' }
    $dir = Join-Path $dir 'clear-notice'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $state = Join-Path $dir ("{0}.txt" -f $hook.session_id)
    $prev = 0
    if (Test-Path -LiteralPath $state) { $prev = [int](Get-Content -LiteralPath $state -TotalCount 1) }
    Set-Content -LiteralPath $state -Value ([Math]::Min($prev, $level)) -Encoding ASCII
    if ($level -le $prev) { exit 0 }
    Set-Content -LiteralPath $state -Value $level -Encoding ASCII

    $msg = "대화가 길어졌습니다. 주제가 끝났다면 다른 주제는 /clear, 이어지는 작업은 /compact를 권장합니다."
    # 콘솔 인코딩과 무관하게 전달되도록 한글을 \u 이스케이프로 쓴다.
    $esc = -join ($msg.ToCharArray() | ForEach-Object { if ([int]$_ -gt 127) { '\u{0:x4}' -f [int]$_ } elseif ($_ -eq '"' -or $_ -eq '\') { '\' + $_ } else { $_ } })
    [Console]::Out.Write('{"systemMessage":"' + $esc + '"}')
} catch {
}
exit 0
