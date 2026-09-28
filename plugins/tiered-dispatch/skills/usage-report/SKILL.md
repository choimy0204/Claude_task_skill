---
name: usage-report
description: tiered-dispatch 서브에이전트 위임 내역(에이전트, 모델, 횟수, 토큰 사용량)을 요약한다. "위임 사용량", "토큰 얼마나 썼어", "서브에이전트 기록", "절약 효과" 같은 요청에 사용.
---

# 위임 사용량 리포트

SubagentStop 훅이 서브에이전트가 끝날 때마다 `usage.jsonl`에 에이전트, 모델, 토큰을 자동으로 기록한다. 이 스킬은 그 기록을 요약한다.

## 실행
PowerShell로 실행한다. 기간(`-Days`, 기본 7)과 프로젝트(`-Project`, 이름 일부)는 사용자 요청에 맞춰 넣는다.

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/usage-report.ps1" -Days 7
```

## 결과 전달
- 스크립트가 출력한 표를 그대로 보여 주고, 한두 줄로 해석을 덧붙인다. (예: 탐색 대부분이 haiku로 처리됨)
- 기록에는 서브에이전트 사용량만 있고 메인 세션 사용량은 없다. 전체 세션 사용량이 필요하면 그렇게 안내한다.
- 비용(달러)은 계산하지 않는다. 가격을 추측하지 않는다.
