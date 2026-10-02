// Offline walkthrough: confidential ballots and certification use the connected database.
(() => {
 const {db,tables}=window.MNCS_DEMO;
 for(const name of ['association_exchange','award_categories','award_assignments','award_candidates','award_ballots','award_audits','award_log'])tables[name]=[];
 const previous=db.rpc.bind(db);
 const connected=new Set(['configure_award_category','assign_award_official','shortlist_award','remove_award_finalist','set_award_phase','submit_award_ballot','certify_award','set_fan_poll','cast_fan_vote','register_fan_profile','generate_tournament','advance_tournament','configure_association_connector','set_connector_enabled','review_shared_competition']);
 db.rpc=async(name,args)=>['public_awards','connector_status','public_performance_summaries'].includes(name)?{data:[],error:null}:connected.has(name)?{data:null,error:{message:'This offline walkthrough does not record ballots, votes or tournaments. Use the connected portal after installing V1.1 SQL.'}}:previous(name,args);
 db.auth.signInWithOtp=async()=>({data:null,error:{message:'Email verification is available on the connected portal only.'}});
})();
