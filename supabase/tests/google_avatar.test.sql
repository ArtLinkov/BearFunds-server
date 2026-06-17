-- 0010 google_avatar suite -- proves the avatar/google_avatar separation
-- (UX Punch List 2026-06-17; brain Area 008 Identity & Family).
-- Run order: auth_shim.sql -> migrations 0001-0010 -> THIS. Wrapped in a rolled-back tx.
-- Asserts via DO/ASSERT; psql with ON_ERROR_STOP exits nonzero on the first failure.
\set ON_ERROR_STOP on
begin;

-- 1) New Google sign-in WITH a photo: handle_new_user must populate google_avatar
--    and leave avatar null (custom-only).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c1', 'carol@fam.test',
   '{"full_name":"Carol","avatar_url":"https://lh3.google/carol.jpg"}');

do $$ begin
  assert (select google_avatar from public.members
            where user_id = '00000000-0000-0000-0000-0000000000c1')
         = 'https://lh3.google/carol.jpg',
         'sign-up photo must land in google_avatar';
  assert (select avatar from public.members
            where user_id = '00000000-0000-0000-0000-0000000000c1') is null,
         'avatar must be null (custom-only) at sign-up';
end $$;

-- 2) New Google sign-in WITHOUT a photo: google_avatar null, avatar null.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c2', 'dave@fam.test', '{"full_name":"Dave"}');
do $$ begin
  assert (select google_avatar from public.members
            where user_id = '00000000-0000-0000-0000-0000000000c2') is null,
         'no avatar_url -> google_avatar null';
  assert (select avatar from public.members
            where user_id = '00000000-0000-0000-0000-0000000000c2') is null,
         'no avatar_url -> avatar null';
end $$;

-- 3) Backfill semantics. Simulate a LEGACY account-linked row (avatar still holds the
--    Google photo, google_avatar empty) plus a manually-added member with a real custom
--    avatar, then re-run the exact predicate the migration backfill uses.
update public.members
  set avatar = 'https://lh3.google/legacy.jpg', google_avatar = null
  where user_id = '00000000-0000-0000-0000-0000000000c2';

insert into public.members (id, family_id, user_id, name, role, avatar)
  select 'm_manual1', family_id, null, 'Grandma', 'member', 'https://custom/grandma.png'
    from public.members where user_id = '00000000-0000-0000-0000-0000000000c1';

update public.members
  set google_avatar = avatar, avatar = null
  where user_id is not null and avatar is not null and google_avatar is null;

do $$ begin
  assert (select google_avatar from public.members
            where user_id = '00000000-0000-0000-0000-0000000000c2')
         = 'https://lh3.google/legacy.jpg',
         'legacy account-linked avatar must move to google_avatar';
  assert (select avatar from public.members
            where user_id = '00000000-0000-0000-0000-0000000000c2') is null,
         'legacy avatar must be cleared after backfill';
  assert (select avatar from public.members where id = 'm_manual1')
         = 'https://custom/grandma.png',
         'manually-added member must keep its custom avatar';
  assert (select google_avatar from public.members where id = 'm_manual1') is null,
         'manually-added member must have no google_avatar';
end $$;

rollback;
