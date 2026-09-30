# tiered-dispatch 플러그인 개발 지침

작업 분배 규칙은 설치된 tiered-dispatch 플러그인이 세션 시작 시 주입한다. 이 파일에 분배 규칙을 다시 적지 않는다.

## 구조
- 플러그인 본체: `plugins/tiered-dispatch/` (규칙 `rules/core.md`, 에이전트 `agents/`, 스킬 `skills/`, 훅 `hooks/hooks.json`, 스크립트 `scripts/`)
- 마켓플레이스: `.claude-plugin/marketplace.json` (이름 `team-claude`)
- 배포 방식: 팀원은 이 폴더 파일을 받아 `install_or_update.bat`(→ `tools/install-or-update.ps1`)을 실행한다. git은 파일 보관용이며 git 마켓플레이스·자동 업데이트는 쓰지 않는다.
- `legacy/`: 이전 bat 설치 방식 보관용. 수정하지 않는다.
- `rollback/v2.4.0/`: v2.4.0 롤백용 스냅샷(`rollback_to_2.4.bat`이 설치). 수정하지 않는다.
- `plugins/tiered-dispatch/scripts/legacy/`: 구버전 판별용 참조본. 내용을 바꾸면 migrate-legacy.ps1이 구버전을 못 알아본다.

## 수정 규칙
- 플러그인 내용을 바꾸면 `plugins/tiered-dispatch/.claude-plugin/plugin.json`의 `version`을 올린다. 올리지 않으면 배치파일을 다시 실행해도 업데이트되지 않는다.
- 스크립트는 Windows PowerShell 5.1 호환으로 쓴다. 한글이 들어간 `.ps1`은 UTF-8 BOM으로 저장한다. (BOM이 없으면 5.1이 잘못 파싱한다)
- 훅 스크립트는 실패해도 세션을 막지 않게 항상 `exit 0`으로 끝낸다.
- `rules/core.md`는 매 세션 컨텍스트에 들어가므로 짧게 유지한다. 상세 절차는 스킬로 옮긴다.
- 수정 후 확인: `claude plugin validate .` 와 `claude plugin validate plugins/tiered-dispatch`
- 동작 테스트는 이 폴더가 아닌 별도 폴더에서 `claude -p --plugin-dir <플러그인 경로>`로 한다. 설치본 반영은 `claude plugin marketplace update team-claude` 후 새 세션에서 확인한다.

## 커밋
- 담당 단위로 커밋을 나누고, 본문에 `Agent: 이름 (모델)`을 적는다. 모델은 호출할 때 넣은 model 값을 따른다.
