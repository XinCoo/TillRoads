const BASE='https://tillroads-production.up.railway.app';
const TOK='tltest001';
const UID='11111111-1111-4111-8111-111111111111';
const H={Authorization:'Bearer '+TOK};
async function timed(label,url){const sw=Date.now();try{const r=await fetch(url,{headers:H});await r.arrayBuffer();return{label,status:r.status,ms:Date.now()-sw};}catch(e){return{label,status:'ERR',ms:Date.now()-sw,err:e.cause?String(e.cause.code||e.cause.message):String(e.message)}}}
(async()=>{
  const rows=[];
  for(let i=0;i<8;i++){
    rows.push(await timed('health#'+i,BASE+'/health'));
    rows.push(await timed('profiles#'+i,BASE+'/users/'+UID+'/exam-profiles'));
    await new Promise(r=>setTimeout(r,1500));
  }
  for(const r of rows)console.log(r.label.padEnd(14),String(r.status).padEnd(5),(r.ms+'ms').padEnd(9),r.err||'');
  const ok=rows.filter(r=>r.status===200).map(r=>r.ms).sort((a,b)=>a-b);
  console.log('ok n=',ok.length,'p50',ok[Math.floor(ok.length*0.5)],'p95',ok[Math.floor(ok.length*0.95)],'max',ok[ok.length-1]);
})();
