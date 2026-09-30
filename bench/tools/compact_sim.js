// 과거 기록으로 "컨텍스트가 T를 넘으면 자동 압축"했을 때 메인 비용 변화를 추정한다. 읽기 전용, 숫자만 출력.
// 모델: 압축 시점에 요약 호출 1회(컨텍스트 읽기 + 출력 SUMMARY 토큰), 이후 컨텍스트 = 기본 + 요약 + 압축 뒤 늘어난 양.
// 압축 뒤 첫 호출은 새 컨텍스트 전체를 캐시 쓰기. 실제 기록의 compact도 그대로 반영(그 지점에서 누적 리셋).
// 실제 기록에서 compact 기록 없이 컨텍스트가 20k 이상 줄면 그 지점에서 오프셋을 줄인다.
// 사용법: node compact_sim.js [최소 호출 수=20]
const fs = require('fs'), path = require('path'), os = require('os');
const ROOT = path.join(os.homedir(), '.claude', 'projects');
const MIN = +(process.argv[2] || 20);
const PRICE = { opus: [5, 0.5, 25], sonnet: [3, 0.3, 15], haiku: [1, 0.1, 5] };
const fam = m => /opus/.test(m) ? 'opus' : /haiku/.test(m) ? 'haiku' : 'sonnet';
const SUMMARY = 12000, TS = [1e12, 100e3, 150e3, 200e3, 300e3, 400e3];
const files = [];
for (const d of fs.readdirSync(ROOT)) { if (/Temp|scratchpad|runs/i.test(d)) continue; const dir = path.join(ROOT, d); try { for (const f of fs.readdirSync(dir)) if (f.endsWith('.jsonl')) files.push(path.join(dir, f)); } catch {} }
const seenG = new Set(); const R = {};
for (const f of files) {
  const ev = []; const seen = new Set();
  for (const line of fs.readFileSync(f, 'utf8').split('\n')) {
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.isSidechain) continue;
    if (o.type === 'system' && o.subtype === 'compact_boundary') { ev.push({ k: 'compact' }); continue; }
    if (o.type === 'assistant' && o.message && o.message.usage && !seen.has(o.message.id) && o.message.model !== '<synthetic>') {
      seen.add(o.message.id); const u = o.message.usage;
      ev.push({ k: 'call', dup: seenG.has(o.message.id), id: o.message.id, m: fam(o.message.model || ''), inp: u.input_tokens || 0, cw: u.cache_creation_input_tokens || 0, cr: u.cache_read_input_tokens || 0, out: u.output_tokens || 0 });
    }
  }
  const calls = ev.filter(e => e.k === 'call' && !e.dup); calls.forEach(c => seenG.add(c.id));
  if (calls.length < MIN) continue;
  const mm = calls[Math.floor(calls.length / 2)].m; if (mm === 'haiku') continue;
  const r = R[mm] || (R[mm] = { s: 0, actual: 0, sim: Object.fromEntries(TS.map(t => [t, { cost: 0, n: 0 }])) }); r.s++;
  const base = Math.min(70000, ...calls.slice(0, 3).map(c => c.inp + c.cw + c.cr)); // 이어 연 세션은 처음부터 크므로 상한
  const actualCost = c => { const [i, rr, o] = PRICE[c.m]; return (c.inp * i + c.cw * i * 1.25 + c.cr * rr + c.out * o) / 1e6; };
  for (const c of calls) r.actual += actualCost(c);
  for (const T of TS) {
    let offset = 0, prevSim = null, cost = 0, n = 0, prevReal = 0;
    for (const e of ev) {
      if (e.k === 'compact') { offset = 0; prevSim = null; continue; }
      if (e.dup) continue;
      const [i, rr, o] = PRICE[e.m];
      const real = e.inp + e.cw + e.cr;
      if (real < prevReal - 20000) { offset = Math.min(offset, Math.max(0, real - base - SUMMARY)); prevSim = null; } // 기록 없는 감소
      prevReal = real;
      let sim = real - offset;
      if (sim > T) { // 압축: 요약 호출 비용 + 이후 오프셋
        cost += (sim * rr + SUMMARY * o) / 1e6; n++;
        offset = real - (base + SUMMARY); sim = base + SUMMARY; prevSim = null;
      }
      const w = prevSim === null ? sim : Math.min(e.cw, sim);
      cost += (e.inp * i + w * i * 1.25 + Math.max(0, sim - w - e.inp) * rr + e.out * o) / 1e6;
      prevSim = sim;
    }
    r.sim[T].cost += cost; r.sim[T].n += n;
  }
}
for (const m in R) {
  const r = R[m];
  console.log(`\n## 메인 ${m}: 세션 ${r.s}개, 실제 $${r.actual.toFixed(0)}`);
  console.log('| 자동 압축 기준 | 압축 횟수 | 추정 비용 | 변화 |\n|---|---|---|---|');
  for (const T of TS) { const s = r.sim[T]; console.log(`| ${T >= 1e12 ? '압축 없음(보정 확인용)' : T / 1000 + 'k'} | ${s.n} | $${s.cost.toFixed(0)} | ${((s.cost / r.actual - 1) * 100).toFixed(1)}% |`); }
}
