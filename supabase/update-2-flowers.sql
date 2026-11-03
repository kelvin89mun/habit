-- 更新 2：伙伴送花 + 今天一起浇水的人数（在 Supabase 的 SQL Editor 执行一次）
-- 伙伴在后台点「送花」，客人下次打开网页，窗台上就会多一朵花，还看得到伙伴的一句话。
-- 客人打卡后，会看到「今天还有几位朋友也浇了水」（只有人数，没有名字）。
-- 这一段可以重复执行，不会影响已经有的资料。

create table if not exists public.cheers (
  id          bigint generated always as identity primary key,
  customer_id uuid not null references public.customers(id) on delete cascade,
  sent_by     uuid default auth.uid() references auth.users(id) on delete set null,
  from_name   text not null default '' check (char_length(from_name) <= 40),
  msg         text not null default '' check (char_length(msg) <= 60),
  day         date not null default ((now() at time zone 'Asia/Kuala_Lumpur')::date),
  created_at  timestamptz not null default now(),
  unique (customer_id, sent_by, day)
);
create index if not exists cheers_customer_idx on public.cheers(customer_id, id desc);

-- who sent it, their name and the day always come from the server, never from the page
create or replace function public.cheers_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.sent_by := auth.uid();
  new.day := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  new.created_at := now();
  new.from_name := coalesce((select name from public.partners where user_id = auth.uid() and status = 'active'), '');
  new.msg := left(btrim(coalesce(new.msg, '')), 60);
  return new;
end $$;
drop trigger if exists cheers_guard on public.cheers;
create trigger cheers_guard before insert on public.cheers
  for each row execute function public.cheers_guard();

alter table public.cheers enable row level security;

-- the customer sees the flowers sent to her; partners see their customers'; leaders see everyone's
drop policy if exists ch_select on public.cheers;
create policy ch_select on public.cheers for select to authenticated
  using (exists (select 1 from public.customers c where c.id = customer_id
                 and (c.user_id = auth.uid()
                      or (c.partner_code is not null and c.partner_code = public.my_partner_code())
                      or public.is_leader())));

-- only her partner (or a leader) can send her a flower, at most one each per day
drop policy if exists ch_insert on public.cheers;
create policy ch_insert on public.cheers for insert to authenticated
  with check (public.my_partner_code() is not null
              and exists (select 1 from public.customers c where c.id = customer_id
                          and ((c.partner_code is not null and c.partner_code = public.my_partner_code())
                               or public.is_leader())));

revoke all on public.cheers from anon;
grant select, insert on public.cheers to authenticated;

-- how many other customers have watered today: a number only, no names
create or replace function public.team_today() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.customers
  where last_check = (now() at time zone 'Asia/Kuala_Lumpur')::date
    and user_id is distinct from auth.uid() $$;

revoke execute on function public.team_today() from public, anon;
grant execute on function public.team_today() to authenticated;
