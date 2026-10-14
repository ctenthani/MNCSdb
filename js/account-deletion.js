(() => {
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
window.MNCS_ACCOUNT_DELETION={mount(target,db,profile){
 if(profile?.role!=='admin'||db.demo)return;
 const bind=()=>target.querySelectorAll('#directory-rows tr').forEach(row=>{
 if(row.querySelector('[data-account-delete]'))return;
 const cells=row.querySelectorAll('td');if(cells.length!==4||cells[2].textContent==='admin')return;
 const email=cells[1].textContent,b=document.createElement('button');b.type='button';b.dataset.accountDelete='';b.textContent='Review deletion';cells[0].appendChild(b);
 b.onclick=async()=>{b.disabled=true;let area=target.querySelector('.account-delete-review');if(!area){area=document.createElement('div');area.className='account-delete-review cleanup-confirm';target.appendChild(area);}area.innerHTML='<p role="status">Checking linked records…</p>';
 try{const users=await db.from('profiles').select('id,email');if(users.error)throw users.error;const id=users.data.find(p=>p.email===email)?.id;if(!id)throw Error('Account changed. Refresh the directory.');const r=await window.MNCS_ACCOUNTS.call(db,{action:'preview-delete',user_id:id});const blockers=r.blockers||[];
 area.innerHTML=`<h4>Review account deletion</h4><p>${esc(r.account.display_name)} · ${esc(r.account.email)} · ${esc(r.account.role)}</p>${blockers.length?'<p>This account has linked records and cannot be deleted:</p><ul>'+blockers.map(x=>`<li>${esc(x.records)}: ${Number(x.count)}</li>`).join('')+'</ul><p>Preserve genuine records. Trial cleanup retains recovery history and may still prevent account deletion.</p>':`<p>Deleting this account permanently removes its login. This cannot be undone.</p><label>Type DELETE ${esc(email)}<input class="account-delete-phrase" autocomplete="off"></label><button class="account-delete-final" disabled>Permanently delete account</button>`}<button class="account-delete-cancel">Cancel</button><p role="status" aria-live="polite"></p>`;
 area.querySelector('.account-delete-cancel').onclick=()=>area.remove();const final=area.querySelector('.account-delete-final');if(final){area.querySelector('input').oninput=e=>final.disabled=e.target.value!==`DELETE ${email}`;final.onclick=async()=>{final.disabled=true;try{const r=await window.MNCS_ACCOUNTS.call(db,{action:'delete-account',user_id:id,confirmation:area.querySelector('input').value});area.querySelector('[role="status"]').textContent=r.message;row.remove();await window.MNCS_REFRESH_PORTAL();}catch(e){area.querySelector('[role="status"]').textContent=e.message;final.disabled=false;}};}
 }catch(e){area.querySelector('[role="status"]').textContent=e.message;}finally{b.disabled=false;}
 };});
 new MutationObserver(bind).observe(target,{childList:true,subtree:true});bind();
}};
})();
