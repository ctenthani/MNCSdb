-- Edit only public association basics, preserving document and review history.
create or replace function public.edit_association_basics(association_key text,association_name text,abbreviation text,sport_name text) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 if association_key !~ '^[A-Za-z0-9_-]{1,80}$'
 or coalesce(length(trim(association_name)),0) not between 1 and 160
 or coalesce(length(trim(abbreviation)),0) not between 1 and 40
 or coalesce(length(trim(sport_name)),0) not between 1 and 100 then raise exception 'Invalid association details'; end if;
 update registry set payload=payload||jsonb_build_object('name',trim(association_name),'shortName',trim(abbreviation),'sport',trim(sport_name)) where collection='associations' and id=association_key;
 if not found then raise exception 'Association not found'; end if;
end $$;
revoke all on function public.edit_association_basics(text,text,text,text) from public,anon;
grant execute on function public.edit_association_basics(text,text,text,text) to authenticated;
