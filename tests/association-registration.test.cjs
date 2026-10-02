const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const context={window:{},document:{}};
vm.createContext(context);vm.runInContext(fs.readFileSync('js/accounts.js','utf8'),context);
const register=context.window.MNCS_ACCOUNTS.registerAssociation;
const details={id:' BUM ',name:' Bowling Union of Malawi ',shortName:'BUM',sport:'Bowling'};
test('association registration uses the authenticated registry and preserves unverified status',async()=>{
 let written;const db={from:table=>{assert.equal(table,'registry');return {insert:async row=>{written=row;return {error:null};}};}};
 const result=await register(db,details);
 assert.equal(written.id,'BUM');assert.equal(written.payload.name,'Bowling Union of Malawi');assert.equal(written.payload.status,'Under Review');assert(!('email' in written.payload));assert.match(result.message,/registered/);
});
test('duplicate IDs and denied registration produce distinct actionable messages',async()=>{
 for(const [code,pattern] of [['23505',/already registered/],['42501',/administrator role.*INSTALL_ALL/],['PGRST205',/registry table/]]){
  const db={from:()=>({insert:async()=>({error:{code}})})};await assert.rejects(()=>register(db,details),pattern);
 }
});
test('invalid association fields are rejected before writing',async()=>{
 await assert.rejects(()=>register({from:()=>{throw Error('Must not write');}},{...details,id:'bad id'}),/Complete all/);
});
