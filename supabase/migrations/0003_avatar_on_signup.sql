-- 0003: handle_new_user also carries the sign-up avatar.
-- Google sign-in (prod) and the dev shim (client core/api/auth.ts) both place
-- an avatar_url in raw_user_meta_data; the linking member should be born with
-- it instead of avatar-less (First-Run & Seeding design, brain).
-- Forward-only: recreates the trigger function from 0001 with `avatar` added
-- to the insert. No table or policy changes; existing rows unaffected.

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

  insert into public.members (id, family_id, user_id, name, role, is_me, avatar)
  values (
    'm_' || replace(new.id::text, '-', ''),
    new_family_id,
    new.id,
    display_name,
    'admin',
    true,
    nullif(new.raw_user_meta_data->>'avatar_url', '')
  );

  return new;
end;
$$;
