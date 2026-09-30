# SessionStart 훅: rules/core.md를 세션 컨텍스트에 주입한다.
# 실패해도 세션을 막지 않도록 항상 exit 0.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $rulesPath = Join-Path $PSScriptRoot "..\rules\core.md"
    if (-not (Test-Path $rulesPath)) { exit 0 }

    $rules = [System.IO.File]::ReadAllText($rulesPath, [System.Text.Encoding]::UTF8)
    $payload = @{
        hookSpecificOutput = @{
            hookEventName     = "SessionStart"
            additionalContext = $rules
        }
    }
    # 비ASCII를 \uXXXX로 이스케이프해 콘솔 인코딩과 무관하게 전달한다.
    $json = $payload | ConvertTo-Json -Compress -Depth 5
    $json = [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    [Console]::Out.Write($json)
}
catch { }
exit 0
