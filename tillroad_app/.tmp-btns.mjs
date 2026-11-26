import { readFileSync } from 'node:fs';
const xml = readFileSync(process.argv[2], 'utf8');
for (const m of xml.match(/<node[^>]*>/g) ?? []) {
  if (!/class="[^"]*Button"/.test(m)) continue;
  const d = /content-desc="([^"]*)"/.exec(m)?.[1] ?? '';
  const t = /text="([^"]*)"/.exec(m)?.[1] ?? '';
  const b = /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/.exec(m)?.[0] ?? '';
  const clickable = /clickable="true"/.test(m);
  console.log(`clickable=${clickable} ${b} :: ${(d||t).replace(/&#10;/g,' | ').slice(0,60)}`);
}
