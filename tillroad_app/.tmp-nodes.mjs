import { readFileSync } from 'node:fs';
const xml = readFileSync(process.argv[2], 'utf8');
const re = /<node[^>]*>/g;
for (const m of xml.match(re) ?? []) {
  const cls = /class="([^"]*)"/.exec(m)?.[1] ?? '';
  const desc = /content-desc="([^"]*)"/.exec(m)?.[1] ?? '';
  const text = /text="([^"]*)"/.exec(m)?.[1] ?? '';
  const bounds = /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/.exec(m);
  const label = (desc || text).replace(/&#10;/g, ' | ').trim();
  if (!label) continue;
  if (process.argv[3] && !label.includes(process.argv[3])) continue;
  if (!bounds) continue;
  const cx = Math.round((+bounds[1] + +bounds[3]) / 2);
  const cy = Math.round((+bounds[2] + +bounds[4]) / 2);
  console.log(`${cx},${cy}\t${bounds[0]}\t${cls.split('.').pop()}\t${label.slice(0, 120)}`);
}
