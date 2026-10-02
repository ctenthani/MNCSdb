const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const source=fs.readFileSync('js/app.js','utf8').split('\nfunction getAssociation')[0];
function contextFor(result){const nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{textContent:'',innerHTML:'',remove(){}});return nodes.get(id);};let sampleFetches=0,rendered=0;const ctx={window:{MNCS_CONFIG:{supabaseUrl:'https://configured.example',supabaseKey:'public'},MNCS_DB:{from:()=>({select:async()=>result})}},document:{getElementById:node,createElement:()=>({setAttribute(){},innerHTML:''}),querySelector:()=>({prepend(){}})},fetch:async()=>{sampleFetches++;throw Error('Live mode must not load sample data');},Intl,Date,console,render:()=>rendered++};vm.createContext(ctx);vm.runInContext(source,ctx);return {ctx,node,sampleFetches:()=>sampleFetches,rendered:()=>rendered};}
test('an empty configured live registry never displays sample athletes, events or results',async()=>{
 const t=contextFor({data:[{collection:'associations',id:'A',payload:{id:'A',name:'Real association',sport:'Bowls'}}],error:null});assert.equal(await vm.runInContext('loadData()',t.ctx),true);
 for(const key of ['players','events','results'])assert.equal(vm.runInContext('state.'+key+'.length',t.ctx),0);
 assert.equal(t.sampleFetches(),0);assert.equal(t.rendered(),1);
});
test('connection failure preserves workspace DOM and exposes a retry without fetching sample records',async()=>{
 const t=contextFor({data:null,error:{message:'Unavailable'}});assert.equal(await vm.runInContext('loadData()',t.ctx),false);assert.match(t.node('data-banner').textContent,/unavailable/);assert.equal(typeof t.node('retry-registry').onclick,'function');assert.equal(t.sampleFetches(),0);assert.equal(t.rendered(),0);
});
