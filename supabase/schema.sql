-- 营养好习惯：资料表与权限（在 Supabase 的 SQL Editor 里执行一次）
-- 客人：只能看、改自己的记录
-- 伙伴：只能看自己客人的记录，可以记礼物、写备注
-- 领导：可以看全部客人、批准伙伴、安排没有伙伴的客人

-- ---------- tables ----------
create table if not exists public.partners (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 40),
  phone      text not null default '' check (phone ~ '^[0-9]{0,15}$'),
  code       text not null unique,
  status     text not null default 'pending' check (status in ('pending','active','disabled')),
  is_leader  boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.customers (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null unique references auth.users(id) on delete cascade,
  partner_code    text references public.partners(code) on update cascade on delete set null,
  state           jsonb not null default '{}'::jsonb check (octet_length(state::text) < 200000),
  name            text not null default '',
  checks          int not null default 0,
  last_check      date,
  start_date      date,
  points          int not null default 0,
  restore_code    text unique,
  restore_expires timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists customers_partner_idx on public.customers(partner_code);

create table if not exists public.customer_notes (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  phone       text not null default '' check (phone ~ '^[0-9]{0,15}$'),
  note        text not null default '' check (char_length(note) <= 500),
  updated_at  timestamptz not null default now()
);

create table if not exists public.gift_log (
  customer_id  uuid not null references public.customers(id) on delete cascade,
  gift_key     text not null check (char_length(gift_key) <= 40),
  delivered_at timestamptz not null default now(),
  delivered_by uuid default auth.uid() references auth.users(id) on delete set null,
  primary key (customer_id, gift_key)
);

-- ---------- helpers ----------
create or replace function public.safe_date(t text) returns date
language plpgsql immutable as $$
begin return t::date; exception when others then return null; end $$;

create or replace function public.my_partner_code() returns text
language sql stable security definer set search_path = public as $$
  select code from public.partners where user_id = auth.uid() and status = 'active' $$;

create or replace function public.is_leader() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.partners where user_id = auth.uid() and status = 'active' and is_leader) $$;

create or replace function public.new_partner_code() returns text
language plpgsql volatile set search_path = public as $$
declare c text; abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(abc, 1 + floor(random() * length(abc))::int, 1); end loop;
    exit when not exists (select 1 from public.partners where code = c);
  end loop;
  return c;
end $$;

-- ---------- guards: people can only change what is theirs ----------
create or replace function public.partners_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare sys boolean := coalesce(current_setting('app.sys', true), '') = '1';
begin
  if tg_op = 'INSERT' then
    new.code := public.new_partner_code();
    if auth.uid() is not null and not sys then
      new.user_id := auth.uid(); new.status := 'pending'; new.is_leader := false;
    end if;
  else
    new.code := old.code; new.user_id := old.user_id; new.created_at := old.created_at;
    if auth.uid() is not null and not sys and not public.is_leader() then
      new.status := old.status; new.is_leader := old.is_leader;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists partners_guard on public.partners;
create trigger partners_guard before insert or update on public.partners
  for each row execute function public.partners_guard();

create or replace function public.customers_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare sys boolean := coalesce(current_setting('app.sys', true), '') = '1'; ck jsonb;
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null and not sys then new.user_id := auth.uid(); end if;
    new.restore_code := null; new.restore_expires := null;
  else
    new.created_at := old.created_at;
    if not sys then
      new.user_id := old.user_id;
      new.restore_code := old.restore_code; new.restore_expires := old.restore_expires;
      if old.partner_code is not null then new.partner_code := old.partner_code; end if;
    end if;
  end if;
  -- a customer can only join an active partner
  if new.partner_code is not null then
    new.partner_code := upper(new.partner_code);
    if not exists (select 1 from public.partners where code = new.partner_code and status = 'active') then
      new.partner_code := case when tg_op = 'UPDATE' then old.partner_code else null end;
    end if;
  end if;
  -- summaries for the dashboards, always worked out from the saved state
  ck := new.state -> 'checks';
  new.name := left(coalesce(new.state ->> 'name', ''), 40);
  if jsonb_typeof(ck) = 'object' then
    select count(*)::int, max(public.safe_date(k)) into new.checks, new.last_check from jsonb_object_keys(ck) as k;
  else
    new.checks := 0; new.last_check := null;
  end if;
  new.start_date := public.safe_date(new.state ->> 'start');
  new.points := case when (new.state ->> 'points') ~ '^-?[0-9]{1,9}$' then (new.state ->> 'points')::int else 0 end;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists customers_guard on public.customers;
create trigger customers_guard before insert or update on public.customers
  for each row execute function public.customers_guard();

-- ---------- row level security ----------
alter table public.partners       enable row level security;
alter table public.customers      enable row level security;
alter table public.customer_notes enable row level security;
alter table public.gift_log       enable row level security;

drop policy if exists p_select on public.partners;
create policy p_select on public.partners for select to authenticated
  using (user_id = auth.uid() or public.is_leader());
drop policy if exists p_insert on public.partners;
create policy p_insert on public.partners for insert to authenticated
  with check (user_id = auth.uid() and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false);
drop policy if exists p_update on public.partners;
create policy p_update on public.partners for update to authenticated
  using (user_id = auth.uid() or public.is_leader());

drop policy if exists c_select on public.customers;
create policy c_select on public.customers for select to authenticated
  using (user_id = auth.uid() or (partner_code is not null and partner_code = public.my_partner_code()) or public.is_leader());
drop policy if exists c_insert on public.customers;
create policy c_insert on public.customers for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists c_update on public.customers;
create policy c_update on public.customers for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists c_delete on public.customers;
create policy c_delete on public.customers for delete to authenticated
  using (user_id = auth.uid());

drop policy if exists n_all on public.customer_notes;
create policy n_all on public.customer_notes for all to authenticated
  using (exists (select 1 from public.customers c where c.id = customer_id
                 and ((c.partner_code is not null and c.partner_code = public.my_partner_code()) or public.is_leader())))
  with check (exists (select 1 from public.customers c where c.id = customer_id
                 and ((c.partner_code is not null and c.partner_code = public.my_partner_code()) or public.is_leader())));

drop policy if exists g_all on public.gift_log;
create policy g_all on public.gift_log for all to authenticated
  using (exists (select 1 from public.customers c where c.id = customer_id
                 and ((c.partner_code is not null and c.partner_code = public.my_partner_code()) or public.is_leader())))
  with check (exists (select 1 from public.customers c where c.id = customer_id
                 and ((c.partner_code is not null and c.partner_code = public.my_partner_code()) or public.is_leader())));

-- ---------- functions the pages call ----------
-- the customer page shows the partner's name and WhatsApp from the link code
create or replace function public.partner_card(p_code text) returns table(name text, phone text)
language sql stable security definer set search_path = public as $$
  select name, phone from public.partners where code = upper(p_code) and status = 'active' $$;

create or replace function public.has_leader() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.partners where is_leader and status = 'active') $$;

-- the very first person to press "我是领导" becomes the leader; after that it does nothing
create or replace function public.claim_first_leader() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.partners where is_leader and status = 'active') then return false; end if;
  perform set_config('app.sys', '1', true);
  update public.partners set status = 'active', is_leader = true where user_id = auth.uid();
  return found;
end $$;

-- a partner makes a restore link when a customer changes phone
create or replace function public.make_restore_code(p_customer uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
begin
  if not exists (select 1 from public.customers where id = p_customer
                 and ((partner_code is not null and partner_code = public.my_partner_code()) or public.is_leader())) then
    raise exception 'not allowed';
  end if;
  perform set_config('app.sys', '1', true);
  update public.customers set restore_code = c, restore_expires = now() + interval '3 days' where id = p_customer;
  return c;
end $$;

-- the customer's new phone takes over her record
create or replace function public.claim_restore(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid; st jsonb; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  select id into cid from public.customers where restore_code = lower(p_code) and restore_expires > now();
  if cid is null then return null; end if;
  delete from public.customers where user_id = me and id <> cid;
  perform set_config('app.sys', '1', true);
  update public.customers set user_id = me, restore_code = null, restore_expires = null
    where id = cid returning state into st;
  return st;
end $$;

-- the leader puts a customer who came without a partner link under a partner
create or replace function public.assign_customer(p_customer uuid, p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_leader() then raise exception 'not allowed'; end if;
  perform set_config('app.sys', '1', true);
  update public.customers set partner_code = upper(p_code) where id = p_customer;
end $$;

-- ---------- who may use what ----------
grant usage on schema public to anon, authenticated;
revoke all on public.partners, public.customers, public.customer_notes, public.gift_log from anon;
grant select, insert, update on public.partners to authenticated;
grant select, insert, update, delete on public.customers to authenticated;
grant select, insert, update, delete on public.customer_notes, public.gift_log to authenticated;

revoke execute on function public.partner_card(text), public.has_leader(), public.claim_first_leader(),
  public.make_restore_code(uuid), public.claim_restore(text), public.assign_customer(uuid, text),
  public.my_partner_code(), public.is_leader(), public.new_partner_code(), public.safe_date(text) from public, anon;
grant execute on function public.partner_card(text), public.has_leader() to anon, authenticated;
grant execute on function public.claim_first_leader(), public.make_restore_code(uuid), public.claim_restore(text),
  public.assign_customer(uuid, text), public.my_partner_code(), public.is_leader() to authenticated;

-- ===== update 1 (home-screen takeover) =====

create table if not exists public.moved_users (
  user_id  uuid primary key,
  moved_at timestamptz not null default now()
);
alter table public.moved_users enable row level security;
revoke all on public.moved_users from anon, authenticated;

create or replace function public.is_moved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.moved_users where user_id = auth.uid()) $$;

-- the customer makes a code for her own record; it rides along in the home-screen icon's address
create or replace function public.make_move_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  perform set_config('app.sys', '1', true);
  update public.customers set restore_code = c, restore_expires = now() + interval '30 days' where user_id = auth.uid();
  if not found then return null; end if;
  return c;
end $$;

-- taking over a record (new phone or home-screen icon) also retires the old account
create or replace function public.claim_restore(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid; old uuid; st jsonb; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  select id, user_id into cid, old from public.customers where restore_code = lower(p_code) and restore_expires > now();
  if cid is null then return null; end if;
  if old = me then return (select state from public.customers where id = cid); end if;
  delete from public.customers where user_id = me and id <> cid;
  perform set_config('app.sys', '1', true);
  update public.customers set user_id = me, restore_code = null, restore_expires = null
    where id = cid returning state into st;
  insert into public.moved_users(user_id) values (old) on conflict do nothing;
  delete from public.moved_users where user_id = me;
  return st;
end $$;

-- a retired account cannot start a second copy of the record
drop policy if exists c_insert on public.customers;
create policy c_insert on public.customers for insert to authenticated
  with check (user_id = auth.uid() and not public.is_moved());

revoke execute on function public.is_moved(), public.make_move_code() from public, anon;
grant execute on function public.is_moved(), public.make_move_code() to authenticated;
