-- Takeoff Studio · Supabase setup (v2: accounts, cloud projects, sharing, usage tracking, admin)
-- Paste ALL of this into Supabase → SQL Editor → New query → Run. Safe to run again after updates.
-- Admin email is set in section 5 — change it there if you sign in to the admin page with another address.

-- 1. Tables ---------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  email      text,
  name       text,
  updated_at timestamptz not null default now()
);
alter table public.profiles add column if not exists created_at timestamptz not null default now();
alter table public.profiles add column if not exists last_seen  timestamptz;
alter table public.profiles add column if not exists blocked    boolean not null default false;

create table if not exists public.projects (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null default auth.uid() references auth.users on delete cascade,
  name       text not null default 'Untitled',
  json       text not null,
  rev        integer not null default 1,
  by         uuid,
  ts         bigint not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists projects_owner_idx on public.projects(owner);

create table if not exists public.project_members (
  project_id uuid not null references public.projects on delete cascade,
  email      text not null check (email = lower(email)),
  role       text not null default 'editor' check (role in ('editor','viewer')),
  added_at   timestamptz not null default now(),
  primary key (project_id, email)
);
create index if not exists project_members_email_idx on public.project_members(email);

create table if not exists public.activity (
  id      bigint generated always as identity primary key,
  at      timestamptz not null default now(),
  user_id uuid references auth.users on delete set null,
  device  text,
  kind    text not null check (kind in ('visit','signup','session','cloud_save','share','export')),
  detail  jsonb not null default '{}'::jsonb
);
create index if not exists activity_at_idx   on public.activity(at desc);
create index if not exists activity_user_idx on public.activity(user_id);

create table if not exists public.app_admins (
  email text primary key check (email = lower(email))
);

-- 2. Helpers (security definer so policies don't recurse) -------------------
create or replace function public.my_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email','')) $$;

create or replace function public.is_blocked() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select blocked from profiles where id = auth.uid()), false)
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_admins where email = public.my_email())
$$;

create or replace function public.is_owner(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from projects where id = p and owner = auth.uid()) and not public.is_blocked()
$$;

create or replace function public.can_access(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not public.is_blocked() and (
         exists (select 1 from projects where id = p and owner = auth.uid())
      or exists (select 1 from project_members where project_id = p and email = public.my_email()))
$$;

create or replace function public.can_edit(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not public.is_blocked() and (
         exists (select 1 from projects where id = p and owner = auth.uid())
      or exists (select 1 from project_members where project_id = p and email = public.my_email() and role = 'editor'))
$$;

create or replace function public.shares_with(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from projects pr
    where public.can_access(pr.id)
      and ( pr.owner = other
         or exists (select 1 from project_members m join profiles pf on pf.id = other
                    where m.project_id = pr.id and m.email = lower(pf.email)) ))
$$;

-- 3. Row-level security -------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.projects        enable row level security;
alter table public.project_members enable row level security;
alter table public.activity        enable row level security;
alter table public.app_admins      enable row level security;   -- no policies: only the admin functions read it

drop policy if exists "profiles: read self and collaborators" on public.profiles;
create policy "profiles: read self and collaborators" on public.profiles
  for select to authenticated using (id = auth.uid() or public.shares_with(id) or public.is_admin());
drop policy if exists "profiles: insert self" on public.profiles;
create policy "profiles: insert self" on public.profiles
  for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles: update self" on public.profiles;
create policy "profiles: update self" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
-- users can change their name/email/last-seen only, never their own "blocked" flag
revoke insert, update on public.profiles from authenticated, anon;
grant  insert (id, email, name, last_seen, updated_at) on public.profiles to authenticated;
grant  update (id, email, name, last_seen, updated_at) on public.profiles to authenticated;

drop policy if exists "projects: read if shared" on public.projects;
create policy "projects: read if shared" on public.projects
  for select to authenticated using (public.can_access(id));
drop policy if exists "projects: create own" on public.projects;
create policy "projects: create own" on public.projects
  for insert to authenticated with check (owner = auth.uid() and not public.is_blocked());
drop policy if exists "projects: edit if editor" on public.projects;
create policy "projects: edit if editor" on public.projects
  for update to authenticated using (public.can_edit(id)) with check (public.can_edit(id));
drop policy if exists "projects: delete own" on public.projects;
create policy "projects: delete own" on public.projects
  for delete to authenticated using (owner = auth.uid());
revoke update on public.projects from authenticated, anon;
grant  update (name, json, rev, by, ts) on public.projects to authenticated;

drop policy if exists "members: owner and member read" on public.project_members;
create policy "members: owner and member read" on public.project_members
  for select to authenticated using (public.is_owner(project_id) or email = public.my_email());
drop policy if exists "members: owner adds" on public.project_members;
create policy "members: owner adds" on public.project_members
  for insert to authenticated with check (public.is_owner(project_id));
drop policy if exists "members: owner changes role" on public.project_members;
create policy "members: owner changes role" on public.project_members
  for update to authenticated using (public.is_owner(project_id)) with check (public.is_owner(project_id));
drop policy if exists "members: owner removes, member leaves" on public.project_members;
create policy "members: owner removes, member leaves" on public.project_members
  for delete to authenticated using (public.is_owner(project_id) or email = public.my_email());

-- activity: anyone may add their own events (visitors anonymously); only admins read
drop policy if exists "activity: add own" on public.activity;
create policy "activity: add own" on public.activity
  for insert to anon, authenticated
  with check ( ((auth.uid() is null and user_id is null) or user_id = auth.uid())
               and coalesce(length(device),0) <= 64 and pg_column_size(detail) < 2000 );
drop policy if exists "activity: admins read" on public.activity;
create policy "activity: admins read" on public.activity
  for select to authenticated using (public.is_admin());
grant insert on public.activity to anon, authenticated;

-- 4. Admin reports (only work for emails listed in app_admins) ---------------
create or replace function public.admin_users()
returns table (id uuid, email text, name text, created_at timestamptz, last_sign_in_at timestamptz,
               last_seen timestamptz, blocked boolean, projects bigint, shared_with bigint,
               sessions bigint, exports bigint, cloud_saves bigint)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
  select u.id, u.email::text, p.name, u.created_at, u.last_sign_in_at, p.last_seen, coalesce(p.blocked,false),
         (select count(*) from projects pr where pr.owner = u.id),
         (select count(*) from project_members m where m.email = lower(u.email)),
         (select count(*) from activity a where a.user_id = u.id and a.kind in ('session','signup')),
         (select count(*) from activity a where a.user_id = u.id and a.kind = 'export'),
         (select count(*) from activity a where a.user_id = u.id and a.kind = 'cloud_save')
  from auth.users u left join profiles p on p.id = u.id
  order by coalesce(p.last_seen, u.last_sign_in_at, u.created_at) desc;
end $$;

create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  select jsonb_build_object(
    'users',          (select count(*) from auth.users),
    'new_7d',         (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'active_7d',      (select count(*) from profiles where last_seen > now() - interval '7 days'),
    'active_30d',     (select count(*) from profiles where last_seen > now() - interval '30 days'),
    'projects',       (select count(*) from projects),
    'shared',         (select count(distinct project_id) from project_members),
    'visits_30d',     (select count(*) from activity where kind = 'visit' and at > now() - interval '30 days'),
    'devices_30d',    (select count(distinct device) from activity where kind = 'visit' and at > now() - interval '30 days'),
    'exports_30d',    (select count(*) from activity where kind = 'export' and at > now() - interval '30 days'),
    'blocked',        (select count(*) from profiles where blocked),
    'daily', (select coalesce(jsonb_agg(d order by d->>'day'), '[]'::jsonb) from (
        select jsonb_build_object(
          'day', to_char(g.day, 'YYYY-MM-DD'),
          'visits',  (select count(*) from activity a where a.kind = 'visit' and a.at::date = g.day),
          'active',  (select count(distinct a.user_id) from activity a where a.user_id is not null and a.at::date = g.day),
          'signups', (select count(*) from auth.users u where u.created_at::date = g.day)) d
        from generate_series(current_date - 29, current_date, interval '1 day') as g(day)) x)
  ) into r;
  return r;
end $$;

create or replace function public.admin_activity(lim int default 200)
returns table (at timestamptz, kind text, email text, device text, detail jsonb)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
  select a.at, a.kind, u.email::text, a.device, a.detail
  from activity a left join auth.users u on u.id = a.user_id
  order by a.at desc limit greatest(1, least(lim, 1000));
end $$;

create or replace function public.admin_set_blocked(uid uuid, b boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  insert into profiles(id, email, blocked) select id, email, b from auth.users where id = uid
  on conflict (id) do update set blocked = excluded.blocked;
end $$;

revoke all on function public.admin_users(), public.admin_stats(), public.admin_activity(int), public.admin_set_blocked(uuid, boolean) from public, anon;
grant execute on function public.admin_users(), public.admin_stats(), public.admin_activity(int), public.admin_set_blocked(uuid, boolean), public.is_admin() to authenticated;

-- 5. Administrators -----------------------------------------------------------
insert into public.app_admins(email) values ('qs.samuelrwanda@gmail.com') on conflict do nothing;
-- to add another admin later:  insert into public.app_admins(email) values ('name@example.com');

-- 6. Live updates ---------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.projects;
exception when duplicate_object then null; end $$;
