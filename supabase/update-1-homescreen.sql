-- 更新 1：主屏幕图标接回原来的记录（在 SQL Editor 执行一次）
-- iPhone 把网页加到主屏幕后，会用另一份储存空间。这个更新让主屏幕图标第一次打开时，
-- 自动接回在 Safari 注册的记录；旧的 Safari 那份不能再另外建一份重复的记录。

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
