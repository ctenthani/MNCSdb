const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),{webcrypto}=require('node:crypto');
test('account directory, deep links, Back and role boundaries survive real workspace rendering',{skip:!process.env.JSDOM_MODULE},async()=>{
 const {JSDOM}=require(process.env.JSDOM_MODULE),dom=new JSDOM(fs.readFileSync('demo.html','utf8'),{url:'https://mncs-demo.example/demo.html#portal/directory',runScripts:'outside-only'}),w=dom.window,d=w.document;
 Object.defineProperty(w,'crypto',{value:webcrypto});w.fetch=async path=>{assert(!String(path).startsWith('https:'));return {ok:true,json:async()=>JSON.parse(fs.readFileSync(path,'utf8'))}};
 w.URL.createObjectURL=()=> 'blob:demo';w.URL.revokeObjectURL=()=>{};
 const settle=async()=>{for(let i=0;i<20;i++)await new Promise(r=>setImmediate(r));};
 const click=s=>{assert(d.querySelector(s),s);d.querySelector(s).click();};
 w.eval(['demo','demo-sports','demo-awards','app','reporting','accounts','award-scoring','awards','tournaments','awards-desk','sports','integration','portal'].map(f=>fs.readFileSync('js/'+f+'.js','utf8')).join('\n'));
 try{
  await settle();click('[data-demo-login="admin"]');await settle();
  assert.equal(d.querySelector('#workspace-directory').hidden,false);assert.equal(w.location.hash,'#portal/directory');
  const db=w.MNCS_DEMO.db;
  for(const role of ['association','reviewer','judge','auditor','admin'])await db.demoAction({action:'create-account',display_name:'TEST '+role,email:'test-'+role+'@mncs.example',password:'test-local-only',role,association_id:role==='association'?'DEMO-ASSOC':null});
  click('#logout');await settle();click('[data-demo-login="admin"]');await settle();click('[data-panel="directory"]');await settle();
  assert.match(d.querySelector('#account-directory').textContent,/TEST association/);
  const filter=d.querySelector('#directory-role');filter.value='judge';filter.dispatchEvent(new w.Event('change'));
  assert.equal(d.querySelectorAll('#directory-rows tr').length,6);
  const search=d.querySelector('#directory-search');search.value='TEST judge';search.dispatchEvent(new w.Event('input'));assert.equal(d.querySelectorAll('#directory-rows tr').length,1);
  click('[data-panel="accounts"]');await settle();assert.equal(w.location.hash,'#portal/accounts');
  w.history.back();await new Promise(r=>setTimeout(r,30));assert.equal(w.location.hash,'#portal/directory');assert.equal(d.querySelector('#workspace-directory').hidden,false);
  assert(d.querySelector('[data-panel="associations"]'));assert.equal(d.querySelector('[data-panel="directory"]').getAttribute('aria-current'),'page');
  click('#logout');await settle();click('[data-demo-login="association"]');await settle();assert(!d.querySelector('[data-panel="directory"]'));assert(!d.querySelector('#account-directory'));assert.equal(w.location.hash,'#portal/overview');
  assert.equal((await db.from('profiles').select('*')).data.length,1);
  await assert.rejects(()=>db.demoAction({action:'create-account',role:'admin'}),/administrator/);
  for(const role of ['reviewer','judge','auditor']){await db.auth.signInWithPassword({email:'test-'+role+'@mncs.example',password:'test-local-only'});assert.equal((await db.from('profiles').select('*')).data.length,1);await assert.rejects(()=>db.demoAction({action:'create-account',role:'admin'}),/administrator/);}
 }finally{dom.window.close();}
});
