-- Minimal Supabase platform pieces the SEF schema depends on.
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;
create role authenticator login noinherit password 'local';
grant anon, authenticated, service_role to authenticator;

create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  encrypted_password text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid
$$;
create function auth.role() returns text language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.role', true),
                         (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')), '')::text
$$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;

grant usage on schema public to anon, authenticated, service_role;
grant all on schema public to service_role;
-- the 'now' override used by the season simulator (unset = real time)
create schema sim;
grant usage on schema sim to anon, authenticated, service_role;
create table sim.clock (id int primary key default 1 check (id = 1), offset_s double precision not null default 0);
insert into sim.clock values (1, 0);
create function sim.now() returns timestamptz language sql stable as $$
  select now() + make_interval(secs => (select offset_s from sim.clock where id = 1)) $$;
create function sim.today() returns date language sql stable as $$
  select (sim.now() at time zone 'America/Los_Angeles')::date $$;
grant select on sim.clock to anon, authenticated, service_role;
grant execute on all functions in schema sim to anon, authenticated, service_role;
