// 과거 대화 기록(~/.claude/projects/*/*.jsonl)으로 메인 비용이 어디서 나오는지 나눈다.
// 읽기 전용. 대화 본문은 출력하지 않고 숫자만 낸다.
// 사용법: node cost_breakdown.js [최소 호출 수=20]
// - 비용 구성: 출력 / 캐시 만료 뒤 재작성(앞 호출과 5분 이상 간격, 쓰기 > 20k) / 일반 캐시 쓰기 / 캐시 읽기
// - 도구 출력 부담: 도구 결과 크기(문자/3.2 ≈ 토큰) × (쓰기 1회 + 이후 같은 구간 호출 수만큼 캐시 읽기)
const fs = require('fs'), path = require('path'), os = require('os');
const ROOT = path.join(os.homedir(), '.claude', 'projects');
const MIN_CALLS = +(process.argv[2] || 20);
const PRICE = { opus: [5, 0.5, 25], sonnet: [3, 0.3, 15], haiku: [1, 0.1, 5] };
const fam = m => /opus/.test(m) ? 'opus' : /haiku/.test(m) ? 'haiku' : 'sonnet';
const CH_PER_TOK = 3.2;

const GLOBAL = new Set();
function load(file) {
  const ev = [], seen = new Set(), toolName = {};
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.isSidechain) continue;
    const t = Date.parse(o.timestamp);
    if (o.type === 'system' && o.subtype === 'compact_boundary') { ev.push({ k: 'compact', t }); continue; }
    const c = o.message && o.message.content;
    if (o.type === 'assistant' && Array.isArray(c)) {
      for (const b of c) if (b.type === 'tool_use') {
        let n = b.name;
        if (n === 'Read') n = b.input && (b.input.limit || b.input.offset) ? 'Read(범위)' : 'Read(전체)';
        if (/^mcp__/.test(n)) n = 'mcp:' + n.split('__')[1].slice(0, 20);
        toolName[b.id] = n;
        ev.push({ k: 'tooluse', t, id: o.message.id, n });
      }
    }
    if (o.type === 'user' && Array.isArray(c)) {
      for (const b of c) if (b.type === 'tool_result') {
        const txt = typeof b.content === 'string' ? b.content : Array.isArray(b.content) ? b.content.map(x => x.text || (x.type === 'image' ? 'x'.repeat(5000) : '')).join('') : '';
        ev.push({ k: 'result', t, n: toolName[b.tool_use_id] || '?', tok: txt.length / CH_PER_TOK });
      }
    } else if (o.type === 'user' && !o.isMeta && !o.isCompactSummary) {
      const txt = typeof c === 'string' ? c : '';
      if (!/^\s*<(local-command|command-name|command-message)/.test(txt)) ev.push({ k: 'user', t });
    }
    if (o.type === 'assistant' && o.message && o.message.usage && !seen.has(o.message.id)) {
      seen.add(o.message.id);
      const u = o.message.usage, m = o.message.model || '';
      if (m === '<synthetic>') continue;
      const c5 = u.cache_creation ? u.cache_creation.ephemeral_5m_input_tokens || 0 : 0;
      ev.push({ k: 'call', id: o.message.id, dup: GLOBAL.has(o.message.id), t, m: fam(m), inp: u.input_tokens || 0, cw: u.cache_creation_input_tokens || 0, cw5: c5, cr: u.cache_read_input_tokens || 0, out: u.output_tokens || 0 });
    }
  }
  for (const e of ev) if (e.k === 'call' && !e.dup) GLOBAL.add(e.id);
  return ev;
}

const wPrice = (c, i) => c.cw ? ((c.cw - c.cw5) * 2 + c.cw5 * 1.25) / c.cw * i : 1.25 * i;
const agg = {};
const A = m => agg[m] || (agg[m] = { sessions: 0, calls: 0, out: 0, idleW: 0, idleN: 0, w: 0, r: 0, inp: 0, tools: {}, base: [], multiTool: 0, toolCalls: 0, userTurns: 0 });

const files = [];
for (const d of fs.readdirSync(ROOT)) {
  if (/Temp|scratchpad|runs/i.test(d)) continue;
  const dir = path.join(ROOT, d);
  try { for (const f of fs.readdirSync(dir)) if (f.endsWith('.jsonl')) files.push(path.join(dir, f)); } catch {}
}
files.sort((a, b) => fs.statSync(a).mtimeMs - fs.statSync(b).mtimeMs);

for (const f of files) {
  const ev = load(f);
  const calls = ev.filter(e => e.k === 'call' && !e.dup);
  if (calls.length < MIN_CALLS) continue;
  const m = fam(calls.map(c => c.m).sort((a, b) => calls.filter(x => x.m === b).length - calls.filter(x => x.m === a).length)[0]);
  if (m === 'haiku') continue;
  const a = A(m); a.sessions++; a.calls += calls.length;
  a.base.push(Math.min(...calls.slice(0, 3).map(c => c.inp + c.cw + c.cr)));
  // 호출별 비용 구성
  let prevT = null;
  for (const c of calls) {
    const [i, r, o] = PRICE[c.m];
    a.out += c.out * o / 1e6; a.inp += c.inp * i / 1e6; a.r += c.cr * r / 1e6;
    const wc = c.cw * wPrice(c, i) / 1e6;
    if (prevT !== null && (c.t - prevT) / 60000 >= 5 && c.cw > 20000) { a.idleW += wc; a.idleN++; } else a.w += wc;
    prevT = c.t;
  }
  // 한 응답에서 도구를 여러 개 부른 비율
  const perMsg = {};
  for (const e of ev) if (e.k === 'tooluse') perMsg[e.id] = (perMsg[e.id] || 0) + 1;
  for (const k in perMsg) { a.toolCalls++; if (perMsg[k] > 1) a.multiTool++; }
  a.userTurns += ev.filter(e => e.k === 'user').length;
  // 도구 결과 부담: 결과 이후 compact 전까지의 호출 수만큼 캐시 읽기
  for (let idx = 0; idx < ev.length; idx++) {
    const e = ev[idx];
    if (e.k !== 'result') continue;
    let later = 0, model = m;
    for (let j = idx + 1; j < ev.length; j++) { if (ev[j].k === 'compact') break; if (ev[j].k === 'call' && !ev[j].dup) { later++; model = ev[j].m; } }
    if (!later) continue;
    const [i, r] = PRICE[model];
    const t = a.tools[e.n] || (a.tools[e.n] = { n: 0, tok: 0, cost: 0, big: 0 });
    t.n++; t.tok += e.tok; if (e.tok > 5000) t.big++;
    t.cost += e.tok * (1.25 * i + (later - 1) * r) / 1e6;
  }
}

const med = x => { if (!x.length) return 0; const s = [...x].sort((p, q) => p - q); return s[Math.floor(s.length / 2)]; };
for (const m of Object.keys(agg)) {
  const a = agg[m], tot = a.out + a.idleW + a.w + a.r + a.inp;
  const pct = v => (v / tot * 100).toFixed(1) + '%';
  console.log(`\n## 메인 ${m}: 세션 ${a.sessions}개, 호출 ${a.calls}회, $${tot.toFixed(2)}, 기본 컨텍스트 중앙값 ${Math.round(med(a.base) / 1000)}k`);
  console.log(`| 구성 | 비용 | 비율 |\n|---|---|---|`);
  console.log(`| 출력 | $${a.out.toFixed(2)} | ${pct(a.out)} |`);
  console.log(`| 캐시 만료 뒤 재작성 (${a.idleN}회) | $${a.idleW.toFixed(2)} | ${pct(a.idleW)} |`);
  console.log(`| 일반 캐시 쓰기 | $${a.w.toFixed(2)} | ${pct(a.w)} |`);
  console.log(`| 캐시 읽기 | $${a.r.toFixed(2)} | ${pct(a.r)} |`);
  console.log(`| 비캐시 입력 | $${a.inp.toFixed(2)} | ${pct(a.inp)} |`);
  console.log(`\n도구를 부른 응답 ${a.toolCalls}개 중 여러 도구를 묶은 응답 ${(a.multiTool / a.toolCalls * 100).toFixed(0)}%, 사용자 입력당 호출 ${(a.calls / a.userTurns).toFixed(1)}회`);
  console.log(`| 도구 | 횟수 | 평균 크기(토큰) | 5k 초과 | 이후 부담 추정 | 비율 |\n|---|---|---|---|---|---|`);
  for (const [n, t] of Object.entries(a.tools).sort((p, q) => q[1].cost - p[1].cost).slice(0, 14))
    console.log(`| ${n} | ${t.n} | ${Math.round(t.tok / t.n)} | ${t.big} | $${t.cost.toFixed(2)} | ${pct(t.cost)} |`);
}
