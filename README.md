# tiered-dispatch

Claude Code가 작업을 모델 등급별로 **자동 분배**하는 플러그인입니다. 별도 명령어 없이 평소처럼 작업하면 됩니다.

- 메인 모델: 설계, 판단, 검토
- `code-searcher` (Haiku): 여러 파일 탐색, 호출 위치 찾기, 로그 분석 (읽기 전용)
- `implementer` (Sonnet): 설계가 확정된 구현, 리팩터링
- `simple-worker` (Haiku): 기계적 작업
- 서브에이전트 사용 내역(에이전트, 모델, 토큰)은 훅이 자동 기록
- 대화 컨텍스트가 커지면(120k, 이후 100k마다) 응답 끝에 `/clear`·`/compact` 권장 문구를 한 번 띄움 (모델 토큰 사용 없음)

## 구성

| 경로 | 역할 |
|---|---|
| `.claude-plugin/marketplace.json` | 팀 마켓플레이스 정의 |
| `plugins/tiered-dispatch/rules/core.md` | 상시 분배 규칙. SessionStart 훅이 세션 시작, /clear, 컴팩트 때 주입 |
| `plugins/tiered-dispatch/agents/` | 서브에이전트 3종 |
| `plugins/tiered-dispatch/skills/handoff` | 큰 작업용 지시서 템플릿 (필요할 때만 로드) |
| `plugins/tiered-dispatch/skills/usage-report` | "위임 사용량 보여줘" 같은 요청에 사용량 요약 |
| `plugins/tiered-dispatch/scripts/` | 규칙 주입, 사용량 기록, 리포트, 구버전 정리, 토큰 절약 훅(큰 파일 통째 Read 1회 차단, 오래 쉰 뒤 /clear 안내) |
| `install_or_update.bat` | 적용: 설치 겸 업데이트 (→ `tools/install-or-update.ps1`) |
| `restore.bat` | 원복: 플러그인 제거, 기본 상태로 복귀 (→ `tools/restore.ps1`) |
| `rollback_to_2.4.bat` | 롤백: v2.4.0으로 되돌림 (스냅샷 `rollback/v2.4.0/`) |
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
- 마지막에 **권장 설정(선택)** 을 하나씩 묻습니다. 동의하면 `~/.claude/settings.json`의 `env`에 추가합니다(변경 전 `settings.json.bak-tiered-dispatch-<시각>`으로 백업, 이미 있는 키는 묻지 않음).
  - `CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000`: 컨텍스트가 200k 근처가 되면 자동 압축. 과거 기록 시뮬레이션에서 메인 비용 Opus 약 −40%, Sonnet 약 −57%(상한). 긴 세션에서는 앞 내용의 세부가 요약됩니다.
  - `BASH_MAX_OUTPUT_LENGTH=15000`: 명령 출력을 15,000자에서 자름(기본 30,000). 긴 로그가 컨텍스트에 쌓이는 것을 줄입니다.
  - 추가한 키는 `~/.claude/tiered-dispatch-env.json`에 기록하며, `restore.bat`이 동의를 받아 값이 그대로인 키만 제거합니다. `CLAUDE_CONFIG_DIR`을 쓰는 경우 그 폴더를 기준으로 합니다.

### 업데이트
1. 새 파일을 받아 **같은 폴더에 덮어씁니다.**
2. `install_or_update.bat`을 다시 실행합니다. 새 버전이 있으면 업데이트합니다.
3. 새 대화부터 적용됩니다.

폴더 위치를 바꿨다면 새 위치에서 실행하세요. 자동으로 새 경로로 다시 등록합니다.

### 원복 (제거)
Claude Code를 모두 종료하고 `restore.bat`을 실행합니다. 새 대화부터 기본 상태로 동작합니다.
- 플러그인을 제거하고 마켓플레이스(`team-claude`) 등록을 해제합니다.
- 설치할 때 옮겨 둔 예전 파일(`~/.claude/tiered-dispatch-migration-backup_*`)이 있으면 목록을 보여 주고, 동의할 때만 제자리로 복원합니다. 이미 있는 파일은 덮어쓰지 않습니다.
- 사용량 기록은 남깁니다.

다시 적용하려면 `install_or_update.bat`을 실행합니다.

### v2.4.0으로 롤백
새 버전에 문제가 있으면 Claude Code를 모두 종료하고 `rollback_to_2.4.bat`을 실행합니다. 폴더 안의 v2.4.0 스냅샷(`rollback/v2.4.0/`)을 다시 설치합니다.
최신 버전으로 돌아오려면 `install_or_update.bat`을 실행합니다. git에서는 태그 `v2.4.0`이 같은 버전입니다.

## 사용량 기록
- 위치: `~/.claude/plugins/data/tiered-dispatch*/usage.jsonl` (서브에이전트 1회당 1줄)
- 요약: Claude에게 "이번 주 위임 사용량 보여줘"라고 하거나 직접 실행합니다.
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File plugins\tiered-dispatch\scripts\usage-report.ps1 -Days 7
  ```
- 메인 세션 사용량은 기록되지 않습니다. 서브에이전트 사용량만 기록됩니다.

## 요구 사항, 제한
- Windows 전용입니다. 훅이 `powershell.exe`(Windows PowerShell 5.1)를 호출합니다. macOS와 Linux는 아직 지원하지 않습니다.
- 위임은 메인이 Opus일 때만 합니다. 메인이 Sonnet이나 Haiku면 직접 처리합니다. (실측: Sonnet 메인은 위임해도 비용이 같거나 늘었습니다)

## 효과 (벤치마크 실측, v2.5.0)
자세한 방법과 원자료는 [bench/README.md](bench/README.md)에 있습니다.

| 구성 | 5개 과제 비용 합 | 품질 |
|---|---|---|
| Opus, 플러그인 없음 | $4.10 | 모두 통과 |
| Opus + 플러그인 v2.4.0 | $3.78 | 모두 통과 |
| **Sonnet 메인** + 플러그인 v2.4.0 | **$1.75** | 모두 통과 |

플러그인 없는 Sonnet은 B1(탐색)·B5(구현)만 측정했고, 두 과제 모두 플러그인을 켠 Sonnet과 비용이 같았습니다.

- 가장 큰 효과는 **메인 모델을 Sonnet으로 쓰는 것**(약 2.4배)입니다. `/model sonnet` 또는 설정의 `"model": "sonnet"`. 설계가 어려운 작업만 `/model opus`로 바꿉니다.
- 두 번째는 **주제가 끝나면 /clear**입니다. 과거 기록 74개 세션 분석에서, 주제가 바뀐 뒤에도 이전 컨텍스트를 계속 읽은 비용이 전체의 약 17~24%(절약 상한의 절반만 반영)였습니다.
- 플러그인 자체(Opus 메인): 큰 탐색 −25%, 여러 주제 세션 −16%. 병렬 구현은 비용 +35% 대신 시간 −40%였고, v2.5.0에서 서브에이전트 도구를 줄여 에이전트당 고정 비용을 −70% 낮췄습니다(병렬 구현 전체 비용은 재측정하지 않음).
- **한계**: 금액은 모두 토큰 사용량을 API 가격으로 환산한 값입니다. Pro·Max 요금제의 사용 한도는 달러로 공개되지 않으므로 "같은 한도로 할 수 있는 작업량"의 비율로만 해석해야 합니다. 과제 수가 적고 대부분 1회 측정이라 ±15% 정도의 편차가 있습니다.
