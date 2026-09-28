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
| `install_or_update.bat` | 설치 겸 업데이트 (→ `tools/install-or-update.ps1`) |
| `legacy/` | 이전 bat 설치 방식 파일 (보관용) |

## 설치, 업데이트

팀원은 이 폴더 파일을 받아 **`install_or_update.bat`만 실행**하면 됩니다. git은 파일 보관용입니다.

### 처음 설치
1. 이 폴더를 통째로 받아 원하는 위치에 둡니다. 설치 후에도 **폴더를 지우지 마세요.** 업데이트할 때 이 폴더를 기준으로 합니다.
2. Claude Code를 모두 종료하고 `install_or_update.bat`을 실행합니다.
3. 새 대화를 시작하면 적용됩니다.

배치파일이 하는 일:
- 예전 bat(`install_claude_agents.bat`) 설치본이 있으면 미리보기를 보여 주고, 동의하면 정리합니다. 변경 전 파일은 `~/.claude/tiered-dispatch-migration-backup_<시각>`에 백업합니다. 설치기가 넣은 파일과 규칙 블록만 지우고, 직접 수정한 파일은 남깁니다.
- `~/.claude/agents/simple-worker.md`, `~/.claude/skills/handoff`가 있으면 중복이라 옮길지 묻습니다.
- 이 폴더를 마켓플레이스(`team-claude`)로 등록하고 플러그인을 설치합니다.

### 업데이트
1. 새 파일을 받아 **같은 폴더에 덮어씁니다.**
2. `install_or_update.bat`을 다시 실행합니다. 새 버전이 있으면 업데이트합니다.
3. 새 대화부터 적용됩니다.

폴더 위치를 바꿨다면 새 위치에서 실행하세요. 자동으로 새 경로로 다시 등록합니다.

### 제거
```
claude plugin uninstall tiered-dispatch@team-claude
claude plugin marketplace remove team-claude
```

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
