(function(global){
const reportRows=(associations,requirements,submissions)=>associations.flatMap(a=>requirements.filter(r=>!r.association_id||r.association_id===a.id).map(r=>{
 const matching=submissions.filter(s=>s.association_id===a.id&&s.kind===r.kind&&s.period===r.period);
 const order={Approved:4,Submitted:3,Returned:2,Draft:1};
 const submission=matching.sort((a,b)=>(order[b.status]||0)-(order[a.status]||0))[0];
 const today=new Intl.DateTimeFormat('en-CA',{timeZone:'Africa/Blantyre',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 return {association:a.name,associationId:a.id,type:r.kind,period:r.period,due:r.due_date||'',status:submission?.status||'Missing',overdue:Boolean(r.due_date&&r.due_date<today&&submission?.status!=='Approved')};
}));
function csv(rows){
 const cell=value=>{let s=String(value??'');if(/^[\s]*[=+@\-]/.test(s))s="'"+s;return '"'+s.replace(/"/g,'""')+'"';};
 const headers=['association','associationId','type','period','due','status','overdue'];
 return [headers,...rows.map(r=>headers.map(h=>r[h]))].map(row=>row.map(cell).join(',')).join('\r\n');
}
global.MNCS_REPORTING={reportRows,csv};
})(typeof window==='undefined'?globalThis:window);
