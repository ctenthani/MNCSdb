const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
test('authenticated user with no profile gets an explanation and can sign out',async()=>{
 const nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{innerHTML:'',textContent:'',addEventListener(){}});return nodes.get(id);};
 let signouts=0;const db={auth:{getSession:async()=>({data:{session:{user:{id:'existing-user'}}}}),signOut:async()=>{signouts++;}},from:name=>{assert.equal(name,'profiles');return {select:()=>({eq:()=>({maybeSingle:async()=>({data:null,error:null})})})};}};
 const context={window:{MNCS_CONFIG:{supabaseUrl:'test',supabaseKey:'test'},supabase:{createClient:()=>db}},document:{getElementById:node},console};
 vm.createContext(context);vm.runInContext(fs.readFileSync('js/portal.js','utf8'),context);
 await new Promise(resolve=>setImmediate(resolve));
 assert.match(node('portal-content').innerHTML,/Account setup incomplete/);
 assert.match(node('portal-notice').textContent,/sign-in succeeded/);
 assert(!node('portal-content').innerHTML.includes('Create account'));
 await node('profile-signout').onclick();assert.equal(signouts,1);assert.match(node('portal-content').innerHTML,/Association and MNCS sign-in/);
});
