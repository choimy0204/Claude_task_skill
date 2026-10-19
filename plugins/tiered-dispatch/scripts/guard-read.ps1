<#
  guard-read.ps1
  Claude Code PreToolUse 훅 (matcher: Read). 한 번에 읽을 양이 크면(범위 없이 큰 파일을 읽거나, offset/limit 범위 자체가 큰 경우) 한 번 막고 Grep + 작은 범위 읽기를 안내한다.
  같은 파일·같은 범위를 다시 Read하면 허용한다(세션별로 막은 요청을 기록).
  이 스크립트는 세션을 절대 중단시키지 않는다 (항상 exit 0).
#>

# 한 번에 읽는 양의 상한(바이트). 약 6K 토큰.
$MaxBytes = 24000
# Read는 limit이 없으면 2000줄까지 읽는다.
$DefaultLines = 2000
$SkipExt = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.pdf', '.ipynb')

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

    if ($hook.tool_name -ne 'Read') { exit 0 }
    $toolInput = $hook.tool_input
    if ($null -eq $toolInput) { exit 0 }

    $path = $toolInput.file_path
    if ([string]::IsNullOrEmpty($path)) { exit 0 }

    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($SkipExt -contains $ext) { exit 0 }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 0 }

    $fullPath = (Resolve-Path -LiteralPath $path).ProviderPath
    if ((New-Object System.IO.FileInfo($fullPath)).Length -le $MaxBytes) { exit 0 }

    $ranged = ($null -ne $toolInput.offset -or $null -ne $toolInput.limit)
    $offset = 1
    if ($null -ne $toolInput.offset) { $offset = [Math]::Max(1, [int]$toolInput.offset) }
    $limit = $DefaultLines
    if ($null -ne $toolInput.limit) { $limit = [Math]::Max(1, [int]$toolInput.limit) }
    $last = $offset + $limit - 1

    # 읽을 범위의 바이트 수를 스트리밍으로 센다.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $lineNo = 0
    $bytes = 0
    foreach ($line in [System.IO.File]::ReadLines($fullPath)) {
        $lineNo++
        if ($lineNo -ge $offset -and $lineNo -le $last) { $bytes += $utf8.GetByteCount($line) + 1 }
    }
    if ($bytes -le $MaxBytes) { exit 0 }

    $dir = $env:CLAUDE_PLUGIN_DATA
    if ([string]::IsNullOrEmpty($dir)) { $dir = Join-Path $env:TEMP 'tiered-dispatch' }
    $dir = Join-Path $dir 'read-guard'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # 가끔 7일 지난 상태 파일을 지운다.
    try {
        if ((Get-Random -Maximum 20) -eq 0) {
            $cutoff = (Get-Date).AddDays(-7)
            Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force
        }
    } catch {
    }

    $key = $fullPath
    if ($ranged) { $key = "{0}#{1}+{2}" -f $fullPath, $offset, $limit }
    $state = Join-Path $dir ("{0}.txt" -f $hook.session_id)
    if (Test-Path -LiteralPath $state) {
        $denied = [System.IO.File]::ReadAllLines($state, [System.Text.Encoding]::UTF8)
        foreach ($d in $denied) {
            if ([string]::Equals($d, $key, [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }
        }
    }
    [System.IO.File]::AppendAllText($state, $key + "`r`n", $utf8)

    $kb = [int][Math]::Round($bytes / 1024)
    $tail = " 읽은 내용은 이후 모든 턴에서 다시 읽혀 비용과 응답 시간이 커집니다. 여러 파일에서 목록·표를 모으는 중이면 tiered-dispatch:code-searcher(haiku)에 맡기고 결과만 받으세요. 그래도 이 범위 전체가 꼭 필요하면 같은 Read를 한 번 더 호출하면 허용됩니다."
    if ($ranged) {
        $msg = "[tiered-dispatch] 요청한 범위가 약 $kb" + "KB입니다. Grep(-n)으로 필요한 위치를 찾고 limit을 100줄 안팎으로 줄여 읽으세요." + $tail
    } else {
        $msg = "[tiered-dispatch] 이 파일은 $lineNo" + "줄(약 $kb" + "KB)입니다. Grep(-n)으로 위치를 찾은 뒤 Read의 offset/limit으로 100줄 안팎씩 필요한 부분만 읽으세요." + $tail
    }
    # 콘솔 인코딩과 무관하게 전달되도록 한글을 \u 이스케이프로 쓴다.
    $esc = -join ($msg.ToCharArray() | ForEach-Object { if ([int]$_ -gt 127) { '\u{0:x4}' -f [int]$_ } elseif ($_ -eq '"' -or $_ -eq '\') { '\' + $_ } else { $_ } })
    [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"' + $esc + '"}}')
} catch {
}
exit 0
