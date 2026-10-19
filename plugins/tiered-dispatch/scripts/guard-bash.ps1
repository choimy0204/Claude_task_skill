<#
  guard-bash.ps1
  Claude Code PreToolUse 훅 (matcher: Bash|PowerShell). 문서 변환 도구(markitdown, pandoc 등)의 전체 출력을 그대로 컨텍스트에 받으려 하면 한 번 막고
  파일로 저장한 뒤 필요한 부분만 보거나 요약만 출력하도록 안내한다. 같은 명령을 다시 호출하면 허용한다.
  이 스크립트는 세션을 절대 중단시키지 않는다 (항상 exit 0).
#>

$Tools = 'markitdown|pandoc|docx2txt|pdftotext|xlsx2csv|in2csv'
# 출력을 파일로 보내거나 줄 수를 제한하면 허용한다.
$Limiters = '>|\|\s*(head|tail|grep|rg|findstr|wc|Select-Object|Select-String|Measure-Object|Out-Null)\b|-First\s+\d|-Tail\s+\d'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
}

try {
    $stdinStream = [Console]::OpenStandardInput()
    $buffer = New-Object System.IO.MemoryStream
    $stdinStream.CopyTo($buffer)
    $hook = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray()) | ConvertFrom-Json

    if ($hook.tool_name -ne 'Bash' -and $hook.tool_name -ne 'PowerShell') { exit 0 }
    $cmd = $hook.tool_input.command
    if ([string]::IsNullOrEmpty($cmd)) { exit 0 }
    if ($cmd -notmatch "(^|[^\w.-])($Tools)(\.exe)?\b") { exit 0 }
    if ($cmd -match $Limiters) { exit 0 }

    $dir = $env:CLAUDE_PLUGIN_DATA
    if ([string]::IsNullOrEmpty($dir)) { $dir = Join-Path $env:TEMP 'tiered-dispatch' }
    $dir = Join-Path $dir 'bash-guard'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # 가끔 7일 지난 상태 파일을 지운다.
    try {
        if ((Get-Random -Maximum 20) -eq 0) {
            $cutoff = (Get-Date).AddDays(-7)
            Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force
        }
    } catch {
    }

    $sha = [System.Security.Cryptography.SHA1]::Create()
    $key = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cmd)) | ForEach-Object { $_.ToString('x2') })
    $state = Join-Path $dir ("{0}.txt" -f $hook.session_id)
    if (Test-Path -LiteralPath $state) {
        foreach ($d in [System.IO.File]::ReadAllLines($state)) {
            if ($d -eq $key) { exit 0 }
        }
    }
    [System.IO.File]::AppendAllText($state, $key + "`r`n")

    $msg = "[tiered-dispatch] 문서 변환 결과 전체가 컨텍스트에 들어오면 이후 모든 턴에서 다시 읽혀 비용과 응답 시간이 커집니다. 출력을 파일로 저장(> out.md)한 뒤 Grep으로 필요한 부분만 보거나, 시트·표 이름과 행 수 같은 요약만 출력하는 스크립트를 쓰세요(office-files 스킬 참고). 전체가 꼭 필요하면 같은 명령을 한 번 더 호출하면 허용됩니다."
    $esc = -join ($msg.ToCharArray() | ForEach-Object { if ([int]$_ -gt 127) { '\u{0:x4}' -f [int]$_ } elseif ($_ -eq '"' -or $_ -eq '\') { '\' + $_ } else { $_ } })
    [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"' + $esc + '"}}')
} catch {
}
exit 0
