// 벤치마크 1회 결과 채점 + 비용·세션 지표 수집.
// 사용법: node grade.js <결과이름> [작업 복사본 폴더]
// 비용은 claude -p JSON의 total_cost_usd(API 단가 환산)를 쓴다. 플랜 한도 계산 방식은 공개되지 않았다.
const fs = require('fs'), path = require('path'), os = require('os'), cp = require('child_process');
const BENCH = path.resolve(__dirname, '..');
const [name, work] = process.argv.slice(2);
const RAW = path.join(BENCH, 'results', 'raw', name);
const task = name.split('_')[0];
const truth = JSON.parse(fs.readFileSync(path.join(BENCH, 'hidden', 'truth.json'), 'utf8'));

// ---- 비용·시간 (모든 claude -p 호출 합계) ----
const calls = fs.readdirSync(RAW).filter(f => f.endsWith('.json') && f !== 'grade.json').sort();
const out = { name, task, cost: 0, api_ms: 0, turns: 0, byModel: {}, calls: {}, errors: [] };
const texts = {};
const sids = new Set(), bySess = {};
for (const f of calls) {
  let j; try { j = JSON.parse(fs.readFileSync(path.join(RAW, f), 'utf8')); } catch { out.errors.push(`${f}: JSON 아님`); continue; }
  const k = f.replace('.json', '');
  texts[k] = j.result || '';
  if (j.is_error) out.errors.push(`${k}: ${j.subtype}`);
  // --resume 로 이어 간 호출의 total_cost_usd·modelUsage 는 세션 누적값이다. 세션마다 가장 큰 값을 쓴다.
  const sid = j.session_id || k, prev = bySess[sid];
  if (!prev || (j.total_cost_usd || 0) >= prev.cost) bySess[sid] = { cost: j.total_cost_usd || 0, mu: j.modelUsage || {} };
  out.api_ms += j.duration_ms || 0; out.turns += j.num_turns || 0;
  out.calls[k] = { cum_cost: +(j.total_cost_usd || 0).toFixed(4), sec: Math.round((j.duration_ms || 0) / 1000), turns: j.num_turns };
  if (j.session_id) sids.add(j.session_id);
}
for (const s of Object.values(bySess)) {
  out.cost += s.cost;
  for (const [m, u] of Object.entries(s.mu)) {
    const key = /opus/.test(m) ? 'opus' : /sonnet/.test(m) ? 'sonnet' : /haiku/.test(m) ? 'haiku' : m;
    out.byModel[key] = +((out.byModel[key] || 0) + (u.costUSD || 0)).toFixed(4);
  }
}
out.cost = +out.cost.toFixed(4);
try { out.wall_sec = +fs.readFileSync(path.join(RAW, 'wall_sec.txt'), 'utf8'); } catch {}

// ---- 세션 기록: 메인 최대 컨텍스트, 서브에이전트 호출, 압축 횟수 ----
const projDir = path.join(os.homedir(), '.claude', 'projects');
function findTranscript(sid) {
  for (const d of fs.readdirSync(projDir)) {
    const p = path.join(projDir, d, sid + '.jsonl');
    if (fs.existsSync(p)) return p;
  }
  return null;
}
const sess = { main_max_ctx: 0, main_calls: 0, compactions: 0, agents: {} };
const seenMsg = new Set();
for (const sid of sids) {
  const p = findTranscript(sid); if (!p) continue;
  for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
    if (!line) continue; let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.type === 'system' && e.subtype === 'compact_boundary') sess.compactions++;
    const m = e.message; if (!m || e.type !== 'assistant' || !m.usage) continue;
    // 응답 하나가 내용 블록마다 줄로 나뉘어 같은 id로 여러 번 기록된다. 사용량은 한 번만 세고, 도구 호출은 모든 줄에서 본다.
    const id = m.id || e.uuid;
    if (!seenMsg.has(id)) {
      seenMsg.add(id);
      const u = m.usage, ctx = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
      sess.main_max_ctx = Math.max(sess.main_max_ctx, ctx); sess.main_calls++;
    }
    for (const c of m.content || []) if (c.type === 'tool_use' && (c.name === 'Agent' || c.name === 'Task')) {
      const a = `${c.input.subagent_type || 'general-purpose'}(${c.input.model || '상속'})`;
      sess.agents[a] = (sess.agents[a] || 0) + 1;
    }
  }
}
out.session = sess;

// ---- 품질 ----
function unittest(dir, hidden) {
  const copied = [];
  for (const h of hidden) { const dst = path.join(dir, 'tests', h); fs.copyFileSync(path.join(BENCH, 'hidden', h), dst); copied.push(dst); }
  const pat = hidden.length === 1 ? hidden[0] : 'test*.py';
  const r = cp.spawnSync('python', ['-m', 'unittest', 'discover', '-s', 'tests', '-t', '.', '-p', pat], { cwd: dir, encoding: 'utf8', timeout: 120000 });
  copied.forEach(f => fs.rmSync(f, { force: true }));
  const s = (r.stderr || '') + (r.stdout || '');
  const ran = +((s.match(/Ran (\d+) test/) || [])[1] || 0);
  const fail = +((s.match(/failures=(\d+)/) || [])[1] || 0) + +((s.match(/errors=(\d+)/) || [])[1] || 0);
  return { ran, passed: ran - fail, ok: /\nOK/.test(s) && ran > 0 };
}
const has = (t, re) => re.test(t);
const q = {};
if (task === 'B1') {
  const t = texts.run || '';
  // 실제 저장소 정보는 공개하지 않는다: bench/local/b1.json {repo, keywords} (git 제외)
  let keys = [];
  try { keys = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'local', 'b1.json'), 'utf8')).keywords; } catch {}
  q.keywords = keys.filter(k => new RegExp(k).test(t)).length + '/' + keys.length;
  q.cs_refs = (t.match(/\.cs:\d+/g) || []).length;
  try { q.repo_status = fs.readFileSync(path.join(RAW, 'repo_status.txt'), 'utf8').trim(); } catch {}
  q.repo_untouched = q.repo_status === '?? .git.7z' || q.repo_status === '';
}
if (task === 'B2' && work) {
  q.visible = unittest(work, []);
  q.tests_untouched = cp.spawnSync('git', ['diff', '--cached', '--quiet', 'base', '--', 'tests'], { cwd: work }).status === 0;
  q.pass = q.visible.ok && q.tests_untouched;
}
if (task === 'B3' && work) {
  q.visible = unittest(work, []);
  q.hidden = unittest(work, ['test_hidden_returns.py']);
  q.pass = q.visible.ok && q.hidden.ok;
}
if (task === 'B5' && work) {
  q.visible = unittest(work, []);
  q.hidden = unittest(work, ['test_hidden_b5.py']);
  q.new_tests = fs.readdirSync(path.join(work, 'tests')).filter(f => /^test_(coupons|importer|weekly|stock_alerts)\.py$/.test(f)).length;
  q.existing_untouched = cp.spawnSync('git', ['diff', '--cached', '--quiet', 'base', '--', 'orderdesk/__init__.py', 'orderdesk/config.py', 'orderdesk/service.py', 'orderdesk/models.py', 'orderdesk/inventory.py', 'orderdesk/money.py', 'tests/helpers.py'], { cwd: work }).status === 0;
  q.pass = q.visible.ok && q.hidden.ok && q.new_tests === 4;
}
if (task === 'B4' && work) {
  const t1 = texts.t1 || '';
  const counts = Object.values(truth.errors).filter(n => new RegExp(`\\b${n}\\b`).test(t1)).length;
  q.t1 = { counts: `${counts}/5`, top: has(t1, /ShippingRateTimeout/), peak: has(t1, /14\s*(시|:00|h)/) };
  q.t1.pass = counts === 5 && q.t1.top && q.t1.peak;
  q.visible = unittest(work, []);
  q.t2 = unittest(work, ['test_hidden_mutation.py']);
  q.t3 = unittest(work, ['test_hidden_export.py']);
  const t4 = texts.t4 || '';
  q.t4 = {
    top: has(t4, /ShippingRateTimeout/) && has(t4, /211/),
    cause: has(t4, /promotions(\.py)?/) && has(t4, /BuyXGetY|apply/),
    columns: has(t4, /order_id[\s,|`]*customer_id[\s,|`]*status[\s,|`]*units[\s,|`]*total/),
  };
  q.t4.pass = q.t4.top && q.t4.cause && q.t4.columns;
  q.pass = q.t1.pass && q.visible.ok && q.t2.ok && q.t3.ok && q.t4.pass;
}
out.quality = q;
console.log(JSON.stringify(out, null, 1));
