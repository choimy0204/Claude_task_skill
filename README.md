# tiered-dispatch

Claude Code가 작업을 모델 등급별로 **자동 분배**하는 플러그인입니다. 별도 명령어 없이 평소처럼 작업하면 됩니다.

- 메인 모델: 설계, 판단, 검토
- `code-searcher` (Haiku): 여러 파일 탐색, 호출 위치 찾기, 로그 분석 (읽기 전용)
- `implementer` (Sonnet): 설계가 확정된 구현, 리팩터링
- `simple-worker` (Haiku): 기계적 작업
- 서브에이전트 사용 내역(에이전트, 모델, 토큰)은 훅이 자동 기록

## 구성

| 경로 | 역할 |
|---|---|
| `.claude-plugin/marketplace.json` | 팀 마켓플레이스 정의 |
| `plugins/tiered-dispatch/rules/core.md` | 상시 분배 규칙. SessionStart 훅이 세션 시작, /clear, 컴팩트 때 주입 |
| `plugins/tiered-dispatch/agents/` | 서브에이전트 3종 |
| `plugins/tiered-dispatch/skills/handoff` | 큰 작업용 지시서 템플릿 (필요할 때만 로드) |
| `plugins/tiered-dispatch/skills/usage-report` | "위임 사용량 보여줘" 같은 요청에 사용량 요약 |
| `plugins/tiered-dispatch/scripts/` | 규칙 주입, 사용량 기록, 리포트, 구버전 정리 스크립트 |
| `team-settings.example.json` | 팀 저장소 `.claude/settings.json`에 넣을 예시 |
| `legacy/` | 이전 bat 설치 방식 파일 (보관용) |

## 설치

### 팀 배포 (권장)
1. 이 폴더를 git 저장소로 올립니다. (예: GitHub `YOUR-ORG/YOUR-REPO`)
2. 팀 프로젝트 저장소의 `.claude/settings.json`에 `team-settings.example.json` 내용을 넣고, `repo` 값을 실제 저장소로 바꿉니다.
3. 팀원이 그 프로젝트에서 Claude Code를 열고 폴더 신뢰를 수락하면 설치를 안내받습니다. 안내가 뜨지 않으면 한 번만 실행합니다.
   ```
   claude plugin install tiered-dispatch@team-claude
   ```

### 이 PC 한 번에 설정 (구버전 정리 + 설치)
`setup_this_pc.bat`을 실행합니다. 구버전 정리 → 직접 만든 분배 설정 정리 → 플러그인 설치를 단계마다 확인하며 진행하고, 옮기거나 지운 파일은 모두 백업합니다.

### 개인 설치 (로컬 경로)
```
claude plugin marketplace add "D:\업무\03_개발\ClaudeSkill"
claude plugin install tiered-dispatch@team-claude
```

### 업데이트, 제거
- 업데이트: `plugin.json`의 `version`을 올려 저장소에 푸시하면, `autoUpdate`가 켜진 팀원은 자동으로 받습니다.
- 제거: `claude plugin uninstall tiered-dispatch@team-claude`

## 이전 bat 설치에서 옮겨 올 때
예전 `install_claude_agents.bat`으로 설치한 PC는 `~/.claude/agents`에 같은 이름의 에이전트가 남아 중복됩니다. 아래 스크립트로 정리합니다. 먼저 `-WhatIf`로 무엇이 바뀌는지 확인하세요. 변경 전 파일은 모두 `~/.claude/tiered-dispatch-migration-backup_<시각>`에 백업됩니다.
```
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\tiered-dispatch\scripts\migrate-legacy.ps1 -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\tiered-dispatch\scripts\migrate-legacy.ps1
```
- 설치기가 넣은 파일과 규칙 블록만 지웁니다. 직접 수정한 파일은 남기고 알려 줍니다.
- 손으로 만든 `agents/simple-worker.md`, `skills/handoff`는 자동으로 지우지 않습니다. 확인 후 직접 지우세요.

## 사용량 기록
- 위치: `~/.claude/plugins/data/tiered-dispatch*/usage.jsonl` (서브에이전트 1회당 1줄)
- 요약: Claude에게 "이번 주 위임 사용량 보여줘"라고 하거나 직접 실행합니다.
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File plugins\tiered-dispatch\scripts\usage-report.ps1 -Days 7
  ```
- 메인 세션 사용량은 기록되지 않습니다. 서브에이전트 사용량만 기록됩니다.

## 요구 사항, 제한
- Windows 전용입니다. 훅이 `powershell.exe`(Windows PowerShell 5.1)를 호출합니다. macOS와 Linux는 아직 지원하지 않습니다.
- 메인이 Sonnet이면 implementer에게 넘기지 않고 직접 구현합니다. 절약 효과는 메인이 Opus일 때 가장 큽니다.
