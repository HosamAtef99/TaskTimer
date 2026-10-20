-- TaskTimer team database
-- Paste this whole file into Supabase → SQL Editor → New query → Run. Safe to run again.
--
-- Who can do what (enforced by the database, not by the app):
--   member : sees and edits only their own tasks
--   leader : also sees every task of their team (live timers included) and can add
--            Incoming tasks for team members; cannot edit anyone's hours or tasks

-- ───────────────────────── Tables ─────────────────────────

create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  team_id    uuid references public.teams(id) on delete set null,
  role       text not null default 'member' check (role in ('member', 'leader')),
  created_at timestamptz not null default now()
);

create table if not exists public.tasks (
  id            uuid primary key,                 -- same id as in the app
  user_id       uuid not null references public.profiles(id) on delete cascade,
  team_id       uuid references public.teams(id) on delete set null,
  parent_id     uuid,                             -- set on amends
  name          text not null default '',
  client        text not null default '',
  status        text not null default 'active' check (status in ('incoming', 'active', 'complete')),
  seconds       double precision not null default 0, -- time counted, not counting a running session
  running_since timestamptz,                      -- set while the timer is running
  work_date     date,
  assigned_by   uuid references public.profiles(id) on delete set null,
  deleted       boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Name of the owner at the time, so a leader still sees who did old tasks after someone leaves the team.
alter table public.tasks add column if not exists owner_name text;

-- When the timer first started (Modhesh's Start Date).
alter table public.tasks add column if not exists started_at timestamptz;

-- Filled in at Done; used for Modhesh's Log Time.
alter table public.tasks add column if not exists deliverables integer;
alter table public.tasks add column if not exists rating integer check (rating between 1 and 5);

create index if not exists tasks_team_created on public.tasks (team_id, created_at);
create index if not exists tasks_user_updated on public.tasks (user_id, updated_at);

-- Tasks read from Modhesh by the TaskTimer Chrome extension, and which TaskTimer task each is linked to.
create table if not exists public.modhesh_tasks (
  user_id        uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  code           text not null,                  -- TSK-SE-…
  title          text not null default '',
  client         text not null default '',
  status         integer,                        -- 1 pending, 6 in progress, 4 completed, 5 pending approver
  status_title   text,
  logged_seconds double precision,               -- time already logged in Modhesh
  view_url       text,
  task_id        uuid,                           -- linked TaskTimer task
  updated_at     timestamptz not null default now(),
  primary key (user_id, code)
);

-- What the extension sent to Modhesh's Log Time by itself.
alter table public.modhesh_tasks add column if not exists submitted_seconds double precision;
alter table public.modhesh_tasks add column if not exists submitted_at timestamptz;
alter table public.modhesh_tasks add column if not exists submit_note text;
alter table public.modhesh_tasks add column if not exists auto_linked boolean not null default false;

-- Each person's Modhesh settings (set in TaskTimer → Settings → Modhesh, read by the Chrome extension).
create table if not exists public.user_settings (
  user_id              uuid primary key default auth.uid() references public.profiles(id) on delete cascade,
  challenge            integer not null default 1,      -- 1 No Challenges, 2 Communication, 3 Briefing, 4 Deadline
  default_rating       integer not null default 5,
  default_deliverables integer not null default 1,
  auto_link            boolean not null default true,
  auto_submit          boolean not null default true,
  extension_seen_at    timestamptz,                     -- the extension checks in here
  extension_version    text,
  updated_at           timestamptz not null default now()
);

-- ───────────────────────── Helpers ─────────────────────────

create or replace function public.my_team() returns uuid
language sql stable security definer set search_path = public as $$
  select team_id from public.profiles where id = auth.uid()
$$;

create or replace function public.is_leader() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'leader' from public.profiles where id = auth.uid()), false)
$$;

-- A profile is created for every new account.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- A task belongs to the team its owner was in when it was created, and stays with that team
-- (moving to another team doesn't take old tasks along). updated_at is kept by the database.
create or replace function public.tasks_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.team_id := (select team_id from public.profiles where id = new.user_id);
    new.owner_name := (select full_name from public.profiles where id = new.user_id);
  else
    new.team_id := old.team_id;
    new.owner_name := coalesce(old.owner_name, (select full_name from public.profiles where id = new.user_id));
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Fill in names on tasks made before owner_name existed.
update public.tasks t set owner_name = p.full_name
  from public.profiles p where p.id = t.user_id and t.owner_name is null;

drop trigger if exists tasks_before_write on public.tasks;
create trigger tasks_before_write before insert or update on public.tasks
  for each row execute function public.tasks_before_write();

-- ───────────────────────── Permissions ─────────────────────────

alter table public.teams    enable row level security;
alter table public.profiles enable row level security;
alter table public.tasks    enable row level security;

-- Teams: see your own team.
drop policy if exists teams_select on public.teams;
create policy teams_select on public.teams for select to authenticated
  using (id = public.my_team());

-- Profiles: see yourself and your teammates; change only your own name.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or (team_id is not null and team_id = public.my_team()));

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

revoke update on public.profiles from authenticated;
grant update (full_name) on public.profiles to authenticated;

-- Settings: each person their own.
alter table public.user_settings enable row level security;
drop policy if exists settings_own on public.user_settings;
create policy settings_own on public.user_settings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Modhesh tasks: each person sees and changes only their own.
alter table public.modhesh_tasks enable row level security;
drop policy if exists modhesh_own on public.modhesh_tasks;
create policy modhesh_own on public.modhesh_tasks for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Tasks
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated
  using (user_id = auth.uid() or (public.is_leader() and team_id = public.my_team()));

drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated
  with check (
    user_id = auth.uid()
    or (
      public.is_leader()
      and status = 'incoming'
      and assigned_by = auth.uid()
      and exists (select 1 from public.profiles p where p.id = user_id and p.team_id = public.my_team())
    )
  );

drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete to authenticated
  using (user_id = auth.uid());

-- ───────────────────────── A new team and its leader (run by hand) ─────────────────────────
-- 1) Authentication → Users → Add user → Create new user (tick Auto Confirm User) for the leader.
-- 2) Then, with the team name and the leader's email:
--
--   insert into public.teams (name) values ('Team Name') on conflict do nothing;
--   update public.profiles
--      set team_id = (select id from public.teams where name = 'Team Name'), role = 'leader'
--    where email = 'leader@company.com';
--
-- The leader adds their own members from TaskTimer (Team → Add Member).

-- ───────────────────────── Older manual setup ─────────────────────────
-- After everyone has created their account in TaskTimer (Settings → Team), run:
--
--   insert into public.teams (name) values ('Abd ElKhalik Team') on conflict do nothing;
--
--   update public.profiles
--      set team_id = (select id from public.teams where name = 'Abd ElKhalik Team')
--    where email in ('member1@socialeyes.com', 'member2@socialeyes.com', 'leader@socialeyes.com');
--
--   update public.profiles set role = 'leader' where email = 'leader@socialeyes.com';
--
-- See who has signed up:
--   select email, full_name, role, (select name from public.teams t where t.id = team_id) as team
--     from public.profiles order by created_at;
