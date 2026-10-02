const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
test('preview supports draft, submission, reviewer approval and history',async()=>{
 const nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{innerHTML:'',textContent:'',value:'',addEventListener(ev,fn){this[ev]=fn;},querySelector(){return {disabled:false};},querySelectorAll(selector){const field=selector.match(/data-(\w+)/)[1];const html=this.innerHTML;this.cache??={};if(this.cache[selector]?.html===html)return this.cache[selector].items;const items= [...html.matchAll(new RegExp(`data-${field}="([^"]+)"(?: data-status="([^"]+)")?`,'g'))].map(m=>({dataset:{[field]:m[1],status:m[2]}}));this.cache[selector]={html,items};return items;}});return nodes.get(id);};
 const context={window:{MNCS_CONFIG:{}},document:{getElementById:node},state:{associations:[{id:'A'}]},getAssociation:()=>({name:'Association A'}),crypto:{randomUUID:()=> 'test-id'},FormData:class {constructor(f){this.f=f;}get(k){return this.f[k]??'';}},console};
 vm.createContext(context);vm.runInContext(fs.readFileSync('js/portal.js','utf8'),context);
 node('demo-association').click();
 const form={kind:'Profile update',period:'2026',document:{size:0},president:'Test President'};
 await node('submission-form').submit({preventDefault(){},target:{...form,querySelector:()=>({disabled:false})}});
 assert.match(node('portal-content').innerHTML,/Draft/);
 let b=node('portal-content').querySelectorAll('[data-submit]')[0];await b.onclick();
 assert.match(node('portal-content').innerHTML,/Submitted/);
 await node('logout').onclick();node('demo-reviewer').click();
 b=node('portal-content').querySelectorAll('[data-review]')[0];await b.onclick();
 assert.match(node('portal-content').innerHTML,/Approved/);
 assert.match(node('portal-content').innerHTML,/Change history/);
 assert.match(node('portal-content').innerHTML,/Test President/);
 assert.equal(node('portal-notice').textContent,'Status updated.');
});
