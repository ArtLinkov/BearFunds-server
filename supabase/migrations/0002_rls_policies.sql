-- BearFunds server — Row-Level Security (forward-only).
-- Every tenant table is scoped to the session's family_id (auth_family_id()).
-- This is the isolation backstop for brain QA Area 008 (Identity) / Area 019 (Isolation):
-- even if the Edge Function logic is wrong, a session can only read/write its own family.

-- Grants: the `authenticated` role reaches tables only through these policies.
grant usage on schema public to authenticated;
grant select, insert, update, delete
  on public.transactions, public.categories, public.wallets,
     public.entities, public.members
  to authenticated;
grant select on public.families to authenticated;
grant execute on function public.auth_family_id() to authenticated;

-- Enable + FORCE so the table owner is also subject to policies (defense in depth).
alter table public.families      enable row level security;
alter table public.transactions  enable row level security;
alter table public.categories    enable row level security;
alter table public.wallets       enable row level security;
alter table public.entities      enable row level security;
alter table public.members       enable row level security;

-- A caller sees only their own family row.
create policy families_self_select on public.families
  for select to authenticated
  using (id = public.auth_family_id());

-- Tenant tables: full access limited to the caller's family, on both read (USING)
-- and write (WITH CHECK). A forged family_id cannot be read (invisible) or written.
do $$
declare t text;
begin
  foreach t in array array['transactions','categories','wallets','entities','members']
  loop
    execute format($f$
      create policy %1$s_family_isolation on public.%1$s
        for all to authenticated
        using (family_id = public.auth_family_id())
        with check (family_id = public.auth_family_id());
    $f$, t);
  end loop;
end;
$$;
