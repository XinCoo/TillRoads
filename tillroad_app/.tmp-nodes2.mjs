import { readFileSync } from 'node:fs';
const xml = readFileSync(process.argv[2], 'utf8');
for (const m of xml.match(/<node[^>]*>/g) ?? []) {
  const d = /content-desc="([^"]*)"/.exec(m)?.[1] ?? '';
  const t = /text="([^"]*)"/.exec(m)?.[1] ?? '';
  const b = /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/.exec(m);
  const cls = /class="([^"]*)"/.exec(m)?.[1] ?? '';
  const clickable = /clickable="true"/.test(m);
  const label = (d || t).replace(/&#10;/g,' | ');
  if (!label.includes(process.argv[3] ?? '关联')) continue;
  console.log(`${cls.split('.').pop()} clickable=${clickable} bounds=${b?.[0]} :: ${label}`);
}
