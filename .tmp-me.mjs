const base = 'http://127.0.0.1:3000';
for (const t of ['tltest001','tltest003']) {
  const r = await fetch(`${base}/me`, { headers: { Authorization: `Bearer ${t}` } });
  console.log(t, r.status, await r.text());
}
