-- 올빼미방 Supabase 설정
-- Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 Run 하세요. 여러 번 실행해도 괜찮아요.

-- 1) 책상 자리표: 누가 몇 층 몇 번 책상에 앉아 있는지
create table if not exists public.owl_seats (
  client_id uuid primary key,
  floor     int  not null check (floor between 2 and 99),
  seat      int  not null check (seat between 0 and 11),
  name      text not null check (char_length(name) between 1 and 12),
  color     int  not null default 0 check (color between 0 and 9),
  outside   boolean not null default false,
  since     timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  unique (floor, seat)
);
alter table public.owl_seats enable row level security;
revoke all on public.owl_seats from anon, authenticated;  -- 표는 아래 함수로만 다뤄요

-- 자리 잡기: 2층부터 빈 책상을 채우고, 만석이면 거절
create or replace function public.owl_claim(p_client uuid, p_name text, p_color int)
returns json language plpgsql security definer set search_path = public as $$
declare
  cap constant int := 160;   -- 동시에 앉을 수 있는 최대 올빼미 수 (Supabase 무료 동시접속 200 안쪽)
  v_floor int; v_seat int; n int;
  v_name text := left(coalesce(nullif(trim(p_name), ''), '올빼미'), 12);
  v_color int := least(greatest(coalesce(p_color, 0), 0), 9);
begin
  lock table owl_seats in share row exclusive mode;
  delete from owl_seats where last_seen < now() - interval '3 minutes';
  select o.floor, o.seat into v_floor, v_seat from owl_seats o where o.client_id = p_client;
  if found then
    update owl_seats set last_seen = now(), name = v_name, color = v_color where client_id = p_client;
    return json_build_object('ok', true, 'floor', v_floor, 'seat', v_seat);
  end if;
  select count(*) into n from owl_seats;
  if n >= cap then
    return json_build_object('ok', false, 'reason', 'full', 'cap', cap);
  end if;
  select f, s into v_floor, v_seat
    from generate_series(2, 99) f cross join generate_series(0, 11) s
    where not exists (select 1 from owl_seats o where o.floor = f and o.seat = s)
    order by f, s limit 1;
  insert into owl_seats (client_id, floor, seat, name, color) values (p_client, v_floor, v_seat, v_name, v_color);
  return json_build_object('ok', true, 'floor', v_floor, 'seat', v_seat);
end $$;

-- 살아 있음 알리기 (30초마다). 자리가 사라졌으면 null 을 돌려줘요.
create or replace function public.owl_beat(p_client uuid, p_name text, p_color int, p_outside boolean)
returns boolean language sql security definer set search_path = public as $$
  update owl_seats
     set last_seen = now(),
         name = left(coalesce(nullif(trim(p_name), ''), '올빼미'), 12),
         color = least(greatest(coalesce(p_color, 0), 0), 9),
         outside = coalesce(p_outside, false)
   where client_id = p_client
  returning true;
$$;

-- 퇴장
create or replace function public.owl_leave(p_client uuid)
returns void language sql security definer set search_path = public as $$
  delete from owl_seats where client_id = p_client;
$$;

-- 건물 전체 현황 (창문 불빛, 층별 인원, 산책 중인 올빼미). client_id 는 내보내지 않아요.
create or replace function public.owl_building()
returns table(floor int, seat int, name text, color int, outside boolean, since timestamptz)
language sql stable security definer set search_path = public as $$
  select o.floor, o.seat, o.name, o.color, o.outside, o.since
    from owl_seats o
   where o.last_seen > now() - interval '3 minutes'
   order by o.floor, o.seat;
$$;

grant execute on function public.owl_claim(uuid, text, int) to anon, authenticated;
grant execute on function public.owl_beat(uuid, text, int, boolean) to anon, authenticated;
grant execute on function public.owl_leave(uuid) to anon, authenticated;
grant execute on function public.owl_building() to anon, authenticated;

-- 2) 개선 의견함: 누구나 보낼 수 있고, 읽기는 대시보드에서 주인만
create table if not exists public.owl_feedback (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind       text not null default 'idea' check (kind in ('idea', 'bug', 'love')),
  name       text check (char_length(name) <= 12),
  body       text not null check (char_length(body) between 1 and 500)
);
alter table public.owl_feedback enable row level security;
drop policy if exists "anyone can send feedback" on public.owl_feedback;
create policy "anyone can send feedback" on public.owl_feedback
  for insert to anon, authenticated with check (true);
grant insert on public.owl_feedback to anon, authenticated;
