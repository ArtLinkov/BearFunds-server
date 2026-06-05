-- 0004: drop members.is_me - Me is client-derived (Schema Contract v1.7).
-- "Me" is the member whose user_id equals the authenticated session uid; a
-- stored flag can drift from that truth (the duplicate-Me bug class), so the
-- column goes away entirely (First-Run & Seeding design, D2/S3, brain).
-- Forward-only: recreates handle_new_user from 0003 without is_me, then drops
-- the column. Destructive by design: is_me carries no information that
-- user_id does not already provide. No RLS/policy references is_me.

create or replace function public.handle_new_user()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, auth
as $$
declare
  new_family_id uuid;
  display_name  text;
begin
  display_name := coalesce(new.raw_user_meta_data->>'full_name', new.email, 'Me');

  insert into public.families (name)
  values (display_name || '''s Family')
  returning id into new_family_id;

  insert into public.members (id, family_id, user_id, name, role, avatar)
  values (
    'm_' || replace(new.id::text, '-', ''),
    new_family_id,
    new.id,
    display_name,
    'admin',
    nullif(new.raw_user_meta_data->>'avatar_url', '')
  );

  return new;
end;
$$;

alter table public.members drop column is_me;
