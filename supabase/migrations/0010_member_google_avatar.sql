-- 0010: separate the Google sign-in photo from the user's custom avatar.
-- members.avatar becomes CUSTOM-ONLY (null by default); a new server-managed
-- google_avatar holds the Google sign-in photo. The client renders with the
-- precedence custom avatar -> google_avatar -> generated initials, so the Google
-- photo is a DEFAULT that never overwrites a custom value (UX Punch List
-- 2026-06-17; brain Area 008 Identity & Family).
--
-- Forward-only: recreates handle_new_user (from 0004) to write the sign-up photo
-- into google_avatar instead of avatar, then backfills existing account-linked
-- members whose avatar was always the Google seed.
--
-- NOT changed here: join_family (0007) keeps writing its avatar argument until the
-- join-form editing slice routes name/avatar/color. google_avatar is server-managed
-- and is deliberately NOT in the API WRITABLE set (see api/_shared/contract.ts), so
-- clients read it via select(*) but can never write it.

alter table public.members add column if not exists google_avatar text;

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

  insert into public.members (id, family_id, user_id, name, role, google_avatar)
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

-- One-time backfill. Account-linked members (user_id set) received their avatar
-- from the sign-up/join trigger, i.e. it is the Google photo: move it to
-- google_avatar and clear avatar so it reads as "no custom avatar". Manually-added
-- members (user_id null) keep their avatar as a genuine custom value.
update public.members
  set google_avatar = avatar,
      avatar = null
  where user_id is not null
    and avatar is not null
    and google_avatar is null;
