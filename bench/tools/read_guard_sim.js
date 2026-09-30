// 과거 대화 기록으로 Read 가드(offset/limit 없는 N줄 초과 Read를 1회 거부)의 효과를 추정한다.
// 읽기 전용. 숫자만 출력한다. 사용법: node read_guard_sim.js
// 가정: 거부된 Read는 필요한 부분 KEEP줄만 읽는 것으로 바뀐다(모델이 다시 전체를 요청한 비율은 반영 못 함 → 상한).
// 부담 = 결과 토큰 × (쓰기 1.25배 + 이후 compact 전 호출 수 × 캐시 읽기 0.1배).
const fs = require('fs'), path = require('path'), os = require('os');
const ROOT = path.join(os.homedir(), '.claude', 'projects');
const PRICE = { opus: 5, sonnet: 3, haiku: 1 };
const fam = m => /opus/.test(m) ? 'opus' : /haiku/.test(m) ? 'haiku' : 'sonnet';
const TH = [150, 200, 300, 400, 600, 1000], KEEP = 120, CH = 3.2;
const agg = {}; let total = 0;
for (const d of fs.readdirSync(ROOT)) {
  if (/Temp|scratchpad|runs/i.test(d)) continue;
  let fl = []; try { fl = fs.readdirSync(path.join(ROOT, d)).filter(f => f.endsWith('.jsonl')); } catch {}
  for (const f of fl) {
    const ev = [], full = {}, seen = new Set();
    for (const line of fs.readFileSync(path.join(ROOT, d, f), 'utf8').split('\n')) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      if (o.isSidechain) continue;
      if (o.type === 'system' && o.subtype === 'compact_boundary') { ev.push({ k: 'c' }); continue; }
      const c = o.message && o.message.content;
      if (o.type === 'assistant' && Array.isArray(c)) for (const b of c)
        if (b.type === 'tool_use' && b.name === 'Read' && !(b.input && (b.input.offset || b.input.limit)) && !/\.(png|jpe?g|gif|webp|bmp|ico|pdf|ipynb)$/i.test(String(b.input && b.input.file_path))) full[b.id] = 1;
      if (o.type === 'user' && Array.isArray(c)) for (const b of c) if (b.type === 'tool_result' && full[b.tool_use_id]) {
        const txt = typeof b.content === 'string' ? b.content : Array.isArray(b.content) ? b.content.map(x => x.text || '').join('') : '';
        const lines = (txt.match(/\n/g) || []).length + 1;
        ev.push({ k: 'r', lines, tok: txt.length / CH });
      }
      if (o.type === 'assistant' && o.message && o.message.usage && !seen.has(o.message.id) && o.message.model !== '<synthetic>') {
        seen.add(o.message.id); ev.push({ k: 'call', m: fam(o.message.model || '') });
        const u = o.message.usage, i = PRICE[fam(o.message.model || '')];
        total += ((u.input_tokens || 0) * i + (u.cache_creation_input_tokens || 0) * i * 1.6 + (u.cache_read_input_tokens || 0) * i * 0.1 + (u.output_tokens || 0) * i * 5) / 1e6;
      }
    }
    for (let x = 0; x < ev.length; x++) {
      if (ev[x].k !== 'r') continue;
      let later = 0, m = 'sonnet';
      for (let y = x + 1; y < ev.length; y++) { if (ev[y].k === 'c') break; if (ev[y].k === 'call') { later++; m = ev[y].m; } }
      if (!later) continue;
      const w = t => t * PRICE[m] * (1.25 + (later - 1) * 0.1) / 1e6;
      for (const T of TH) if (ev[x].lines > T) {
        const a = agg[T] || (agg[T] = { n: 0, saved: 0 });
        a.n++; a.saved += w(ev[x].tok) - w(ev[x].tok * KEEP / ev[x].lines);
      }
    }
  }
}
console.log(`메인 전체 비용(추정) $${total.toFixed(0)}`);
console.log('| 기준 줄 수 | 해당 Read | 절약 상한 | 비율 |\n|---|---|---|---|');
for (const T of TH) { const a = agg[T] || { n: 0, saved: 0 }; console.log(`| ${T} | ${a.n} | $${a.saved.toFixed(0)} | ${(a.saved / total * 100).toFixed(1)}% |`); }
