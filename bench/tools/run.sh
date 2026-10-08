#!/bin/bash
# 벤치마크 1회 실행 + 채점.
# 사용법: run.sh <구성> <작업> <태그> [컨텍스트변형]
#   구성: D(Opus, 플러그인 없음) A(Opus+v2.4.0) B(opusplan, 플러그인 없음) C0(Sonnet+v2.4.0) C(Sonnet+개발본)
#         S(Sonnet, 플러그인 없음) E(Opus+개발본) H(Sonnet+개발본 변형: Sonnet 메인도 탐색은 code-searcher 위임) HF(H와 같되 위임을 반드시 하도록 강제)
#   작업: B1(큰 탐색, 실제 저장소 읽기 전용) B2(작은 수정) B3(여러 파일 구현) B4(주제 4개 긴 세션) B5(나눌 수 있는 큰 구현)
#   컨텍스트변형(B4만): w1m / w200k / w120k / w80k (자동 압축 창), compact(주제마다 /compact), clear(주제마다 새 세션)
# 환경변수: BENCH_WORK(작업 복사본 폴더), B1_REPO(큰 탐색 대상 저장소)
set -u
BENCH="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$BENCH/.." && pwd)"
WORK="${BENCH_WORK:?BENCH_WORK 필요}"
# 실제 저장소 경로는 bench/local/b1.json 의 repo (git 제외)
B1_REPO="${B1_REPO:-$(node -e "console.log(require(process.argv[1]).repo)" "$BENCH/local/b1.json" 2>/dev/null)}"
cfg=$1; task=$2; tag=$3; ctx=${4:-}
name="${task}_${cfg}${ctx:+_$ctx}_${tag}"
RAW="$BENCH/results/raw/$name"
mkdir -p "$RAW" "$WORK/plugins"

# 플러그인 스냅샷: v2.4.0 은 커밋 493da33 기준
if [ ! -d "$WORK/plugins/v240" ]; then
  (cd "$ROOT" && git archive 493da33 plugins/tiered-dispatch | tar -x -C "$WORK/plugins" && mv "$WORK/plugins/plugins/tiered-dispatch" "$WORK/plugins/v240" && rmdir "$WORK/plugins/plugins")
fi
# H 변형: 개발본을 복사해 core.md의 "Sonnet·Haiku 메인은 위임 안 함" 줄만 바꾼다 (매번 새로 만든다)
if [ "$cfg" = H ] || [ "$cfg" = HF ]; then
  rm -rf "$WORK/plugins/dev_h"; cp -r "$ROOT/plugins/tiered-dispatch" "$WORK/plugins/dev_h"
  sed -i 's/^- 메인(시스템에 안내된 현재 세션 모델)이 Sonnet이나 Haiku면 위임하지 않고 직접 한다..*$/- 메인이 Haiku면 위임하지 않고 직접 한다. 메인이 Sonnet이면 큰 탐색만 code-searcher에 위임하고 implementer는 쓰지 않는다./' "$WORK/plugins/dev_h/rules/core.md"
  [ "$cfg" = HF ] && sed -i 's/^- 메인이 Haiku면 위임하지 않고 직접 한다. 메인이 Sonnet이면 .*$/- 메인이 Haiku면 위임하지 않고 직접 한다. 메인이 Sonnet이어도 위 1번(큰 탐색·분석)은 반드시 code-searcher로 위임한다. implementer는 쓰지 않는다./' "$WORK/plugins/dev_h/rules/core.md"
  grep -qE '메인이 Sonnet이(면 큰 탐색만|어도 위 1번)' "$WORK/plugins/dev_h/rules/core.md" || { echo "H 변형 실패"; exit 1; }
fi
case $cfg in
  D)  MODEL=opus;     PLUG=() ;;
  A)  MODEL=opus;     PLUG=(--plugin-dir "$WORK/plugins/v240") ;;
  B)  MODEL=opusplan; PLUG=() ;;
  C0) MODEL=sonnet;   PLUG=(--plugin-dir "$WORK/plugins/v240") ;;
  C)  MODEL=sonnet;   PLUG=(--plugin-dir "$ROOT/plugins/tiered-dispatch") ;;
  S)  MODEL=sonnet;   PLUG=() ;;
  E)  MODEL=opus;     PLUG=(--plugin-dir "$ROOT/plugins/tiered-dispatch") ;;
  H|HF) MODEL=sonnet; PLUG=(--plugin-dir "$WORK/plugins/dev_h") ;;
  *) echo "unknown cfg $cfg"; exit 1 ;;
esac
ENVJSON=""
case $ctx in
  w1m) ENVJSON=',"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"1000000"}' ;;
  w200k) ENVJSON=',"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"200000"}' ;;
  w120k) ENVJSON=',"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"120000"}' ;;
  w80k) ENVJSON=',"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"80000"}' ;;
esac
SETTINGS='{"enabledPlugins":{"tiered-dispatch@team-claude":false,"design-lean@design-lean-dev":false,"headroom@headroom-marketplace":false}'"$ENVJSON"'}'

# cc <출력이름> <권한모드> <세션ID|""> <프롬프트> [추가 인자...]
cc() {
  local out=$1 pm=$2 sid=$3 prompt=$4; shift 4
  local res=(); [ -n "$sid" ] && res=(--resume "$sid")
  timeout 1500 claude -p "$@" --model "$MODEL" --settings "$SETTINGS" "${PLUG[@]}" --permission-mode "$pm" \
    --output-format json "${res[@]}" "$prompt" < /dev/null > "$RAW/$out.json" 2> "$RAW/$out.err"
}
sid_of() { node -e "try{console.log(require(process.argv[1]).session_id||'')}catch{console.log('')}" "$RAW/$1.json"; }
prep_fixture() {
  local d="$WORK/$name"
  rm -rf "$d"; cp -r "$BENCH/fixture" "$d"
  [ "$1" = fixed ] && python "$BENCH/hidden/reference.py" "$d" bulk
  (cd "$d" && git init -q && git config core.autocrlf false && git add -A && git -c user.email=b@b -c user.name=bench commit -qm base && git tag base) >&2
  echo "$d"
}
# opusplan 은 큰 작업에서만 계획 모드 → 실행 (사용자가 실제로 쓰는 방식)
plan_then_run() {  # <출력이름> <세션ID|""> <프롬프트>
  if [ "$cfg" = B ]; then
    cc "$1_plan" plan "$2" "$3"
    cc "$1" bypassPermissions "$(sid_of "$1_plan")" "계획대로 진행해줘. 확인 없이 끝까지 진행해."
  else
    cc "$1" bypassPermissions "$2" "$3"
  fi
}

start=$(date +%s)
case $task in
  B1)
    cd "$B1_REPO"
    cc run bypassPermissions "" "$(cat "$BENCH/tasks/B1.txt")" --disallowedTools "Edit Write NotebookEdit"
    git -C "$B1_REPO" status --short > "$RAW/repo_status.txt"
    ;;
  B2)
    d=$(prep_fixture bug); cd "$d"
    cc run bypassPermissions "" "$(cat "$BENCH/tasks/B2.txt")"
    ;;
  B3|B5)
    d=$(prep_fixture fixed); cd "$d"
    plan_then_run run "" "$(cat "$BENCH/tasks/$task.txt")"
    ;;
  B4)
    d=$(prep_fixture fixed); cd "$d"
    sid=""
    for t in 1 2 3 4; do
      p="$(cat "$BENCH/tasks/B4_t$t.txt")"
      [ "$ctx" = clear ] && sid=""
      if [ "$ctx" = compact ] && [ -n "$sid" ]; then
        cc "t${t}_compact" bypassPermissions "$sid" "/compact 다음 주제로 넘어간다. 지금까지의 결론(수치, 원인 위치, 추가한 API와 형식)만 짧게 남겨라."
        s2=$(sid_of "t${t}_compact"); [ -n "$s2" ] && sid=$s2
      fi
      if [ "$t" = 2 ] || [ "$t" = 3 ]; then plan_then_run "t$t" "$sid" "$p"; else cc "t$t" bypassPermissions "$sid" "$p"; fi
      s2=$(sid_of "t$t"); [ -n "$s2" ] && sid=$s2
    done
    ;;
esac
echo $(( $(date +%s) - start )) > "$RAW/wall_sec.txt"
[ -n "${d:-}" ] && (cd "$d" && git add -A && git diff --cached --stat base > "$RAW/diff_stat.txt" && git diff --cached base > "$RAW/diff.patch")
node "$BENCH/tools/grade.js" "$name" "${d:-}" > "$RAW/grade.json" 2> "$RAW/grade.err"
echo "$name done"
