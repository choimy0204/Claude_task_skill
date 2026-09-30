// 메인 컨텍스트가 무엇으로 채워지는지 나눈다. 읽기 전용, 숫자만 출력.
// 호출 k-1 → k 사이 컨텍스트 증가분을 그 사이에 들어온 항목(직전 응답의 텍스트·도구 입력, 도구 결과, 사용자 입력, 시스템 첨부)의
// 문자 수 비율로 나누고, 증가분 × (쓰기 1회 + compact 전까지 이후 호출 수만큼 읽기)를 항목 부담으로 본다.
// 사용법: node ctx_composition.js [최소 호출 수=20]
const fs = require('fs'), path = require('path'), os = require('os');
const ROOT = path.join(os.homedir(), '.claude', 'projects');
const MIN = +(process.argv[2] || 20);
const PRICE = { opus: [5, 0.5], sonnet: [3, 0.3], haiku: [1, 0.1] };
const fam = m => /opus/.test(m) ? 'opus' : /haiku/.test(m) ? 'haiku' : 'sonnet';
const files = [];
for (const d of fs.readdirSync(ROOT)) { if (/Temp|scratchpad|runs/i.test(d)) continue; const dir = path.join(ROOT, d); try { for (const f of fs.readdirSync(dir)) if (f.endsWith('.jsonl')) files.push(path.join(dir, f)); } catch {} }
const G = {}; const seenG = new Set();
for (const f of files) {
  const ev = []; const seen = new Set(); const tn = {};
  for (const line of fs.readFileSync(f, 'utf8').split('\n')) {
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.isSidechain) continue;
    if (o.type === 'system' && o.subtype === 'compact_boundary') { ev.push({ k: 'compact' }); continue; }
    const c = o.message && o.message.content;
    if (o.type === 'assistant' && o.message) {
      if (Array.isArray(c)) for (const b of c) {
        if (b.type === 'text') ev.push({ k: 'item', cat: '모델 출력:텍스트', ch: b.text.length });
        else if (b.type === 'thinking') ev.push({ k: 'item', cat: '모델 출력:thinking', ch: (b.thinking || '').length });
        else if (b.type === 'tool_use') { tn[b.id] = b.name; const s = JSON.stringify(b.input || {}).length; ev.push({ k: 'item', cat: /^(Write|Edit|MultiEdit|NotebookEdit)$/.test(b.name) ? '모델 출력:파일 쓰기 입력' : /^Agent|Task$/.test(b.name) ? '모델 출력:에이전트 프롬프트' : '모델 출력:기타 도구 입력', ch: s }); }
      }
      const u = o.message.usage;
      if (u && !seen.has(o.message.id) && o.message.model !== '<synthetic>') { seen.add(o.message.id); ev.push({ k: 'call', dup: seenG.has(o.message.id), id: o.message.id, m: fam(o.message.model || ''), ctx: (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0) }); }
    } else if (o.type === 'user' && c) {
      if (Array.isArray(c)) for (const b of c) {
        if (b.type === 'tool_result') { const n = tn[b.tool_use_id] || '?'; const txt = typeof b.content === 'string' ? b.content : Array.isArray(b.content) ? b.content.map(x => x.text || (x.type === 'image' ? 'x'.repeat(4800) : '')).join('') : ''; ev.push({ k: 'item', cat: '도구 결과:' + (/^mcp__/.test(n) ? 'mcp' : n), ch: txt.length }); }
        else if (b.type === 'text') ev.push({ k: 'item', cat: /^<system-reminder>|^<command|^<local-command/.test(b.text) || o.isMeta ? '시스템·훅 첨부' : '사용자 입력', ch: b.text.length });
        else if (b.type === 'image') ev.push({ k: 'item', cat: '사용자 입력', ch: 4800 });
      } else ev.push({ k: 'item', cat: o.isMeta || o.isCompactSummary || /^<system-reminder>|^<command|^<local-command/.test(c) ? '시스템·훅 첨부' : '사용자 입력', ch: c.length });
    } else if ((o.type === 'attachment' && !/prompt_snapshot|hook_success|queued_command/.test(o.attachment && o.attachment.type)) || (o.type === 'system' && o.content)) ev.push({ k: 'item', cat: '시스템·훅 첨부', ch: JSON.stringify(o.attachment || o.content || '').length });
  }
  const calls = ev.filter(e => e.k === 'call' && !e.dup);
  for (const e of calls) seenG.add(e.id);
  if (calls.length < MIN) continue;
  const mm = fam(calls[Math.floor(calls.length / 2)].m);
  if (mm === 'haiku') continue;
  const g = G[mm] || (G[mm] = { s: 0, cat: {}, base: 0, tot: 0 }); g.s++;
  // 호출 위치 목록
  const idx = []; ev.forEach((e, i) => { if (e.k === 'call' && !e.dup) idx.push(i); });
  const later = []; // 각 호출 이후 compact 전까지 호출 수
  for (let a = 0; a < idx.length; a++) { let n = 0; for (let j = idx[a] + 1; j < ev.length; j++) { if (ev[j].k === 'compact') break; if (ev[j].k === 'call' && !ev[j].dup) n++; } later.push(n); }
  let prevCtx = null;
  for (let a = 0; a < idx.length; a++) {
    const call = ev[idx[a]]; const [i, r] = PRICE[call.m];
    const unit = (1.25 * i + later[a] * r) / 1e6;
    if (prevCtx === null || call.ctx < prevCtx * 0.6) { g.cat['기본(시스템 프롬프트·도구 정의·CLAUDE.md)'] = (g.cat['기본(시스템 프롬프트·도구 정의·CLAUDE.md)'] || 0) + call.ctx * unit; prevCtx = call.ctx; continue; }
    const delta = call.ctx - prevCtx; prevCtx = call.ctx;
    if (delta <= 0) continue;
    const from = a === 0 ? 0 : idx[a - 1] + 1; const items = {}; let tot = 0;
    for (let j = from; j < idx[a]; j++) if (ev[j].k === 'item') { items[ev[j].cat] = (items[ev[j].cat] || 0) + ev[j].ch; tot += ev[j].ch; }
    // 직전 호출 블록의 출력 항목은 호출 줄보다 앞/뒤에 섞여 있으므로 범위를 직전 호출 바로 앞까지 넓힌다
    if (!tot) { g.cat['미분류'] = (g.cat['미분류'] || 0) + delta * unit; continue; }
    for (const k in items) g.cat[k] = (g.cat[k] || 0) + delta * items[k] / tot * unit;
  }
}
for (const m in G) {
  const g = G[m]; const tot = Object.values(g.cat).reduce((s, v) => s + v, 0);
  console.log(`\n## 메인 ${m}: 세션 ${g.s}개, 입력 쪽 비용(쓰기+읽기) $${tot.toFixed(0)}`);
  console.log('| 항목 | 부담 | 비율 |\n|---|---|---|');
  for (const [k, v] of Object.entries(g.cat).sort((a, b) => b[1] - a[1]).slice(0, 18)) console.log(`| ${k} | $${v.toFixed(0)} | ${(v / tot * 100).toFixed(1)}% |`);
}
