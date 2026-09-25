-- Takeoff Studio · Supabase setup
-- Paste all of this into Supabase → SQL Editor → New query, then click Run. Safe to run again.

-- 1. Tables ---------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  email      text,
  name       text,
  updated_at timestamptz not null default now()
);

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

-- 2. Access helpers (security definer so policies don't recurse) ------------
create or replace function public.my_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email','')) $$;

create or replace function public.is_owner(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from projects where id = p and owner = auth.uid())
$$;

create or replace function public.can_access(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from projects where id = p and owner = auth.uid())
      or exists (select 1 from project_members where project_id = p and email = public.my_email())
$$;

create or replace function public.can_edit(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from projects where id = p and owner = auth.uid())
      or exists (select 1 from project_members where project_id = p and email = public.my_email() and role = 'editor')
$$;

create or replace function public.shares_with(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from projects pr
    where public.can_access(pr.id)
      and ( pr.owner = other
         or exists (select 1 from project_members m join profiles pf on pf.id = other
                    where m.project_id = pr.id and m.email = lower(pf.email)) )
  )
$$;

-- 3. Row-level security -------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.projects        enable row level security;
alter table public.project_members enable row level security;

drop policy if exists "profiles: read self and collaborators" on public.profiles;
create policy "profiles: read self and collaborators" on public.profiles
  for select to authenticated using (id = auth.uid() or public.shares_with(id));
drop policy if exists "profiles: insert self" on public.profiles;
create policy "profiles: insert self" on public.profiles
  for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles: update self" on public.profiles;
create policy "profiles: update self" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "projects: read if shared" on public.projects;
create policy "projects: read if shared" on public.projects
  for select to authenticated using (public.can_access(id));
drop policy if exists "projects: create own" on public.projects;
create policy "projects: create own" on public.projects
  for insert to authenticated with check (owner = auth.uid());
drop policy if exists "projects: edit if editor" on public.projects;
create policy "projects: edit if editor" on public.projects
  for update to authenticated using (public.can_edit(id)) with check (public.can_edit(id));
drop policy if exists "projects: delete own" on public.projects;
create policy "projects: delete own" on public.projects
  for delete to authenticated using (owner = auth.uid());

-- editors may change the content, never the owner
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

-- 4. Live updates ---------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.projects;
exception when duplicate_object then null; end $$;
