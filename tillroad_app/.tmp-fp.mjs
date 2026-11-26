import { createHash } from 'node:crypto';
for (const t of ['tltest001','tltest002','tltest003']) {
  console.log(t, createHash('sha256').update(t).digest('hex').slice(0,16));
}
