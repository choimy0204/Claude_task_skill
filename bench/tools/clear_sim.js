// 과거 대화 기록(~/.claude/projects/*/*.jsonl)으로 "주제가 바뀔 때 /clear 했다면" 절약량을 추정한다.
// 읽기 전용. 대화 본문은 출력하지 않고 숫자만 낸다.
// 사용법: node clear_sim.js [최소 호출 수=30]
// 주제 경계 추정: 앞 활동과 G분 이상 떨어진 사용자 입력. 경계에서 /clear 했다면
// 이후 호출의 컨텍스트에서 "경계 직전 컨텍스트 - 기본 컨텍스트"만큼이 빠진다고 본다(상한).
const fs = require('fs'), path = require('path'), os = require('os');
const ROOT = path.join(os.homedir(), '.claude', 'projects');
const MIN_CALLS = +(process.argv[2] || 30);
const GAPS = [5, 15, 30, 60];
const PRICE = { opus: [5, 0.5, 25], sonnet: [3, 0.3, 15], haiku: [1, 0.1, 5] }; // 입력, 캐시읽기, 출력 ($/M)
const fam = m => /opus/.test(m) ? 'opus' : /haiku/.test(m) ? 'haiku' : 'sonnet';

const GLOBAL = new Set(); // 이어 연 세션이 복사한 이전 호출은 한 번만 센다
function load(file) {
  const ev = [], seen = new Set();
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.isSidechain) continue;
    const t = Date.parse(o.timestamp);
    if (o.type === 'system' && o.subtype === 'compact_boundary') ev.push({ k: 'compact', t });
    else if (o.type === 'user' && !o.isMeta && !o.isCompactSummary) {
      const c = o.message && o.message.content;
      const txt = typeof c === 'string' ? c : Array.isArray(c) && !c.some(x => x.type === 'tool_result') ? c.map(x => x.text || '').join('') : null;
      if (txt !== null && !/^\s*<(local-command|command-name|command-message)/.test(txt)) ev.push({ k: 'user', t });
    } else if (o.type === 'assistant' && o.message && o.message.usage && !seen.has(o.message.id)) {
      seen.add(o.message.id);
      const u = o.message.usage, m = o.message.model || '';
      if (m === '<synthetic>') continue;
      const c5 = u.cache_creation ? u.cache_creation.ephemeral_5m_input_tokens || 0 : 0;
      const cw = u.cache_creation_input_tokens || 0;
      ev.push({ k: 'call', id: o.message.id, dup: GLOBAL.has(o.message.id), t, m: fam(m), inp: u.input_tokens || 0, cw, cw5: c5, cr: u.cache_read_input_tokens || 0, out: u.output_tokens || 0 });
    }
  }
  for (const e of ev) if (e.k === 'call' && !e.dup) GLOBAL.add(e.id);
  return ev;
}

const cost = c => { const [i, r, o] = PRICE[c.m]; const w1 = c.cw - c.cw5; return (c.inp * i + c.cw5 * i * 1.25 + w1 * i * 2 + c.cr * r + c.out * o) / 1e6; };

function simulate(ev, G) {
  const calls = ev.filter(e => e.k === 'call');
  const base = Math.min(...calls.slice(0, 3).map(c => c.inp + c.cw + c.cr));
  let carry = 0, lastT = null, lastCtx = base, saved = 0, bounds = 0, segCalls = [], cur = 0;
  const boundCtx = [];
  for (const e of ev) {
    if (e.k === 'compact') { carry = 0; }
    else if (e.k === 'user') {
      if (lastT !== null && (e.t - lastT) / 60000 >= G && lastCtx - base > 5000) {
        carry = lastCtx - base; bounds++; boundCtx.push(lastCtx); segCalls.push(cur); cur = 0;
      }
    } else {
      cur++;
      const ctx = e.inp + e.cw + e.cr;
      const rm = e.dup ? 0 : Math.max(0, Math.min(carry, ctx - base));
      if (rm) {
        const [i, r] = PRICE[e.m];
        const fromW = Math.min(rm, e.cw), fromR = Math.min(rm - fromW, e.cr);
        const wPrice = e.cw ? ((e.cw - e.cw5) * 2 + e.cw5 * 1.25) / e.cw * i : 2 * i;
        saved += (fromW * wPrice + fromR * r) / 1e6;
      }
      lastCtx = ctx;
    }
    lastT = e.t;
  }
  segCalls.push(cur);
  return { saved, bounds, boundCtx, segCalls };
}

const files = [];
for (const d of fs.readdirSync(ROOT)) {
  if (/Temp|scratchpad|runs/i.test(d)) continue; // 벤치 실행 제외
  const dir = path.join(ROOT, d);
  try { for (const f of fs.readdirSync(dir)) if (f.endsWith('.jsonl')) files.push(path.join(dir, f)); } catch {}
}

files.sort((a, b) => fs.statSync(a).mtimeMs - fs.statSync(b).mtimeMs);
const tot = { cost: 0, n: 0, calls: 0 }, byG = Object.fromEntries(GAPS.map(g => [g, { saved: 0, bounds: 0, boundCtx: [], segCalls: [] }]));
const rows = [];
for (const f of files) {
  const ev = load(f);
  const calls = ev.filter(e => e.k === 'call' && !e.dup);
  if (calls.length < MIN_CALLS) continue;
  const c = calls.reduce((s, x) => s + cost(x), 0);
  tot.cost += c; tot.n++; tot.calls += calls.length;
  const r = { id: path.basename(f, '.jsonl').slice(0, 8), calls: calls.length, cost: c, maxCtx: Math.max(...calls.map(x => x.inp + x.cw + x.cr)), compacts: ev.filter(e => e.k === 'compact').length };
  for (const g of GAPS) {
    const s = simulate(ev, g); const a = byG[g];
    a.saved += s.saved; a.bounds += s.bounds; a.boundCtx.push(...s.boundCtx); a.segCalls.push(...s.segCalls.slice(1));
    r['g' + g] = s.saved;
  }
  rows.push(r);
}
const med = a => { if (!a.length) return 0; const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };
console.log(`세션 ${tot.n}개 (호출 ${MIN_CALLS}회 이상), 호출 ${tot.calls}회, 총 비용 $${tot.cost.toFixed(2)} (API 가격 환산)`);
console.log('| 경계 간격 | 경계 수 | 경계 시 컨텍스트 중앙값 | 경계 후 호출 수 중앙값 | 절약 상한 | 비율 | 절반 반영 |');
console.log('|---|---|---|---|---|---|---|');
for (const g of GAPS) {
  const a = byG[g];
  console.log(`| ${g}분 | ${a.bounds} | ${Math.round(med(a.boundCtx) / 1000)}k | ${med(a.segCalls)} | $${a.saved.toFixed(2)} | ${(a.saved / tot.cost * 100).toFixed(1)}% | ${(a.saved / tot.cost * 50).toFixed(1)}% |`);
}
console.log('\n상위 세션 (비용순 10개)');
console.log('| 세션 | 호출 | 비용 | 최대 컨텍스트 | 압축 | 5분 | 15분 | 30분 | 60분 |');
console.log('|---|---|---|---|---|---|---|---|---|');
for (const r of rows.sort((a, b) => b.cost - a.cost).slice(0, 10))
  console.log(`| ${r.id} | ${r.calls} | $${r.cost.toFixed(2)} | ${Math.round(r.maxCtx / 1000)}k | ${r.compacts} | ${GAPS.map(g => (r['g' + g] / r.cost * 100).toFixed(0) + '%').join(' | ')} |`);
