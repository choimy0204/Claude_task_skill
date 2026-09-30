// results/raw/*/grade.json 을 모아 마크다운 표로 출력한다.
// 사용법: node summary.js [이름 필터 정규식]
const fs = require('fs'), path = require('path');
const RAW = path.resolve(__dirname, '..', 'results', 'raw');
const re = new RegExp(process.argv[2] || '.');
const rows = [];
for (const d of fs.readdirSync(RAW).filter(d => re.test(d)).sort()) {
  let g; try { g = JSON.parse(fs.readFileSync(path.join(RAW, d, 'grade.json'), 'utf8')); } catch { continue; }
  const q = g.quality || {};
  let qual = q.pass === undefined ? '' : q.pass ? '통과' : '실패';
  if (g.task === 'B1') qual = `키워드 ${q.keywords}, .cs:줄 ${q.cs_refs}, 원본 ${q.repo_untouched ? '무변경' : '변경됨!'}`;
  if ((g.task === 'B3' || g.task === 'B5') && q.hidden) qual += ` (숨은 ${q.hidden.passed}/${q.hidden.ran})`;
  if (g.task === 'B4' && q.t1) qual += ` (t1 ${q.t1.pass ? 'O' : 'X'} t2 ${q.t2.passed}/${q.t2.ran} t3 ${q.t3.passed}/${q.t3.ran} t4 ${q.t4.pass ? 'O' : 'X'})`;
  const agents = Object.entries(g.session.agents).map(([k, v]) => `${k}×${v}`).join(' ');
  const models = Object.entries(g.byModel).map(([k, v]) => `${k} ${v.toFixed(2)}`).join(', ');
  rows.push(`| ${d} | $${g.cost.toFixed(2)} | ${g.wall_sec}s | ${models} | ${Math.round(g.session.main_max_ctx / 1000)}k | ${g.session.compactions} | ${agents || '-'} | ${qual} |`);
}
console.log('| 실행 | 비용 | 시간 | 모델별 | 최대 컨텍스트 | 압축 | 서브에이전트 | 품질 |');
console.log('|---|---|---|---|---|---|---|---|');
console.log(rows.join('\n'));
