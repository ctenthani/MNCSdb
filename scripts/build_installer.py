"""Build one transactional installer from the versioned migration sources."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
files=['schema.sql','v0.3-migration.sql','v0.4-migration.sql','v0.5-migration.sql','v0.6-migration.sql','v0.6.2-migration.sql','v0.7-migration.sql','researched-associations.sql','v0.9-migration.sql','v1.0-migration.sql','v1.1-migration.sql']
chunks=[]
for name in files:
 s=(root/'supabase'/name).read_text()
 # Defer this index to its final definition, so existing multi-category award
 # nominations do not encounter the obsolete one-submission-per-period index.
 if name=='schema.sql':
  s=re.sub(r'^create unique index unique_current_submission[^;]+;\n','',s,flags=re.M)
 s=re.sub(r'create table (?!if not exists)', 'create table if not exists ',s,flags=re.I)
 s=re.sub(r'create (unique )?index (?!if not exists)',lambda m:'create '+(m.group(1) or '')+'index if not exists ',s,flags=re.I)
 s=re.sub(r'create function ', 'create or replace function ',s,flags=re.I)
 s=re.sub(r'add column (?!if not exists)', 'add column if not exists ',s,flags=re.I)
 s=re.sub(r'create policy (\w+) on ([\w.]+)', lambda m:f'drop policy if exists {m.group(1)} on {m.group(2)};\n'+m.group(0),s,flags=re.I)
 s=s.replace('drop index public.unique_current_submission;', 'drop index if exists public.unique_current_submission;')
 s=s.replace('drop constraint submissions_kind_check;', 'drop constraint if exists submissions_kind_check;')
 s=s.replace('alter table public.submissions add constraint nomination_shape', 'alter table public.submissions drop constraint if exists nomination_shape;\nalter table public.submissions add constraint nomination_shape')
 s=s.replace('insert into public.initial_admin_setup(id) values(1);','insert into public.initial_admin_setup(id) values(1) on conflict(id) do nothing;')
 s=s.replace("false,10485760,array['application/pdf']);", "false,10485760,array['application/pdf']) on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['application/pdf'];")
 chunks.append('-- Component: '+name+'\n'+s)
header='''-- MNCS v1.1 COMPLETE INSTALLER
-- Run this ONE file in Supabase SQL Editor. Replaces running individual migrations.
-- Supports a new project or the earlier app schemas; preserves records and setup state.
-- All changes commit together. If an existing incompatible record causes an error,
-- the transaction rolls back: inspect the error rather than deleting records.
-- Sourced association candidates are included; no accounts, passwords or secrets.
BEGIN;
'''
(root/'supabase/INSTALL_ALL.sql').write_text(header+'\n'.join(chunks)+'\nCOMMIT;\n')
