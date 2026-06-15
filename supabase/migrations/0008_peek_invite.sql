-- BearFunds server - peek_invite (S9b-2 addendum, forward-only, additive).
-- Lets a not-yet-member joiner read ONLY the inviting family's display name (+ the
-- invite role) for a VALID pending token, so the client Join Form can name the family
-- being joined. The joiner is not a member of that family yet, so RLS would hide both
-- the invite and the family row - hence SECURITY DEFINER, scoped to a single
-- pending+unexpired token lookup.
--
-- Disclosure is deliberate and minimal: the family display name (+ role) to a holder of
-- a valid invite link. No member, transaction, or other family data is reachable.
--
-- CONTROL-PLANE: reached via supabase.rpc, not the action endpoint. No table, policy,
-- or Schema Contract change.

create or replace function public.peek_invite(p_token text)
  returns table(family_name text, invite_role text)
  language sql
  stable
  security definer
  set search_path = public, auth
as $fn$
  select f.name, i.role
  from public.invites i
  join public.families f on f.id = i.family_id
  where i.token = p_token
    and i.status = 'pending'
    and i.expires_at > now();
$fn$;

grant execute on function public.peek_invite(text) to authenticated;
