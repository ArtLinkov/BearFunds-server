-- TEST-ONLY shim. Recreates the minimal Supabase `auth` surface (auth.users,
-- auth.uid(), auth.jwt(), the `authenticated` role) so the real migrations run
-- unchanged against a stock Postgres. NEVER applied to a real Supabase project —
-- Supabase provides all of this natively. Apply this BEFORE the migrations in tests.


do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);

-- auth.uid(): the 'sub' claim of the request JWT, or NULL when unset (service context).
create or replace function auth.uid()
  returns uuid language sql stable as $$
  select case
    when coalesce(current_setting('request.jwt.claims', true), '') = '' then null
    else (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')::uuid
  end;
$$;

create or replace function auth.jwt()
  returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;
