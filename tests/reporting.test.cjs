const test=require('node:test'),assert=require('node:assert/strict');require('../js/reporting.js');
const {reportRows,csv}=global.MNCS_REPORTING;
test('reporting distinguishes missing, draft, submitted and approved against requirements',()=>{
 const associations=[{id:'A',name:'A'},{id:'B',name:'B'}];
 const requirements=[{kind:'Annual report',period:'2026',due_date:'2000-01-01',association_id:null}];
 let rows=reportRows(associations,requirements,[{association_id:'A',kind:'Annual report',period:'2026',status:'Approved'}]);
 assert.equal(rows[0].status,'Approved');assert.equal(rows[0].overdue,false);assert.equal(rows[1].status,'Missing');assert.equal(rows[1].overdue,true);
 rows=reportRows(associations,requirements,[{association_id:'A',kind:'Annual report',period:'2026',status:'Draft'}]);assert.equal(rows[0].status,'Draft');
});
test('requirements for one association do not apply to another',()=>{assert.equal(reportRows([{id:'B'}],[{association_id:'A'}],[]).length,0);});
test('CSV quotes commas and blocks spreadsheet formula interpretation',()=>{const output=csv([{association:'=HYPERLINK("evil")',type:'AGM, minutes'}]);assert(output.includes('"\'=HYPERLINK(""evil"")"'));assert(output.includes('"AGM, minutes"'));});
