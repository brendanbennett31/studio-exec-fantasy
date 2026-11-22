-- Gold Derby odds: clean replace, duplicate guard, and a reload from the
-- combined-odds page https://www.goldderby.com/odds/combined-odds/oscars-nominations-2027/
--
-- Why: gold_derby_odds had drifted into garbage (Best Actor listing an
-- actress, Best Actress listing Malkovich, film titles glued to people's
-- names like "Christopher Nolan The Odyssey", 28 "directors", 38 "original
-- screenplays", the same film repeated, and only 8 of the 21 categories Gold
-- Derby now predicts). This migration:
--   1. replaces any old unique key with one that fits the data: one row per
--      (season, category, film, performer) -- two Odyssey supporting actresses
--      are two nominees, an exact repeat is impossible;
--   2. adds replace_gold_derby_odds(), a service-role-only function that swaps
--      a whole season's rows in ONE transaction, so a scrape can never leave a
--      half-written or empty table (the new Apps Script scraper calls it);
--   3. loads today's page into it: 21 categories x top 5 contenders.
--
-- Column meaning (unchanged): film_title = the film; performer_name = the
-- person (actors, director) or the song title (Best Song), null for film-level
-- categories; nom_odds = Gold Derby's combined nomination odds (%); win_odds
-- stays 0 -- this page doesn't publish win odds.
--
-- Note: the combined page lists only each category's top 5, so Best Picture
-- (10 slots) is limited to 5 known contenders.

-- 1. one nominee, one row
do $$
declare r record;
begin
  for r in select conname from pg_constraint where conrelid = 'public.gold_derby_odds'::regclass and contype = 'u' loop
    execute format('alter table public.gold_derby_odds drop constraint %I', r.conname);
  end loop;
  for r in
    select i.relname as idx
    from pg_index x join pg_class i on i.oid = x.indexrelid
    where x.indrelid = 'public.gold_derby_odds'::regclass and x.indisunique and not x.indisprimary
  loop
    execute format('drop index if exists public.%I', r.idx);
  end loop;
end $$;

-- 2. atomic season replace (service role only; called by Apps Script)
create or replace function public.replace_gold_derby_odds(p_season text, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n integer;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) < 50 then
    raise exception 'Refusing to replace odds: expected at least 50 rows, got %', coalesce(jsonb_array_length(p_rows), 0);
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_rows) as x(category text, film_title text, nom_odds numeric)
    where coalesce(btrim(x.category), '') = '' or coalesce(btrim(x.film_title), '') = '' or x.nom_odds is null
  ) then
    raise exception 'Refusing to replace odds: a row is missing category, film_title or nom_odds';
  end if;

  delete from gold_derby_odds where season = p_season;
  insert into gold_derby_odds (season, category, film_title, performer_name, nom_odds, win_odds, updated_at)
  select p_season, btrim(x.category), btrim(x.film_title), nullif(btrim(coalesce(x.performer_name, '')), ''),
         x.nom_odds, coalesce(x.win_odds, 0), now()
  from jsonb_to_recordset(p_rows) as x(category text, film_title text, performer_name text, nom_odds numeric, win_odds numeric);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.replace_gold_derby_odds(text, jsonb) from public;
revoke execute on function public.replace_gold_derby_odds(text, jsonb) from anon, authenticated;
grant execute on function public.replace_gold_derby_odds(text, jsonb) to service_role;

create unique index if not exists gold_derby_odds_nominee_key
  on public.gold_derby_odds (season, category, film_title, (coalesce(performer_name, '')));

-- 3. load today's page
select public.replace_gold_derby_odds('2027', (
  select jsonb_agg(jsonb_build_object('category', category, 'film_title', film_title, 'performer_name', performer_name, 'nom_odds', nom_odds))
  from (values
  ('Best Picture', 'The Odyssey', null, 97.11),
  ('Best Picture', 'La Bola Negra', null, 96.66),
  ('Best Picture', 'Wild Horse Nine', null, 95.59),
  ('Best Picture', 'Project Hail Mary', null, 92.33),
  ('Best Picture', 'You Can See Everything', null, 89.97),
  ('Best Director', 'The Odyssey', 'Christopher Nolan', 96.60),
  ('Best Director', 'La Bola Negra', 'Javier Ambrossi, Javier Calvo', 94.90),
  ('Best Director', 'Wild Horse Nine', 'Martin McDonagh', 74.90),
  ('Best Director', 'The Invite', 'Olivia Wilde', 70.53),
  ('Best Director', 'You Can See Everything', 'Nathan Fielder and Lance Oppenheim', 70.36),
  ('Best Actress', 'The Debut', 'Julianne Moore', 95.35),
  ('Best Actress', 'The Invite', 'Olivia Wilde', 90.46),
  ('Best Actress', 'Obsession', 'Inde Navarrette', 87.04),
  ('Best Actress', 'Rose', 'Sandra Hüller', 72.46),
  ('Best Actress', 'All of a Sudden', 'Virginie Efira', 57.72),
  ('Best Actor', 'Wild Horse Nine', 'John Malkovich', 96.11),
  ('Best Actor', 'The Odyssey', 'Matt Damon', 94.73),
  ('Best Actor', 'Elsinore', 'Andrew Scott', 90.84),
  ('Best Actor', 'Project Hail Mary', 'Ryan Gosling', 62.24),
  ('Best Actor', 'Primetime', 'Robert Pattinson', 50.32),
  ('Best Supporting Actress', 'The Odyssey', 'Anne Hathaway', 94.61),
  ('Best Supporting Actress', 'The Odyssey', 'Samantha Morton', 88.03),
  ('Best Supporting Actress', 'All of a Sudden', 'Tao Okamoto', 67.88),
  ('Best Supporting Actress', 'La Bola Negra', 'Penelope Cruz', 65.82),
  ('Best Supporting Actress', 'The Invite', 'Penelope Cruz', 62.97),
  ('Best Supporting Actor', 'The Debut', 'Paul Giamatti', 95.54),
  ('Best Supporting Actor', 'Wild Horse Nine', 'Sam Rockwell', 91.41),
  ('Best Supporting Actor', 'Artificial', 'Andrew Garfield', 85.14),
  ('Best Supporting Actor', 'La Bola Negra', 'Guitarricadelafuente', 76.22),
  ('Best Supporting Actor', 'The Odyssey', 'John Leguizamo', 75.47),
  ('Best Adapted Screenplay', 'La Bola Negra', null, 97.87),
  ('Best Adapted Screenplay', 'The Invite', null, 96.66),
  ('Best Adapted Screenplay', 'The Odyssey', null, 93.97),
  ('Best Adapted Screenplay', 'Project Hail Mary', null, 86.36),
  ('Best Adapted Screenplay', 'All of a Sudden', null, 73.65),
  ('Best Original Screenplay', 'Wild Horse Nine', null, 97.43),
  ('Best Original Screenplay', 'The Debut', null, 96.19),
  ('Best Original Screenplay', 'Artificial', null, 75.91),
  ('Best Original Screenplay', 'Obsession', null, 74.84),
  ('Best Original Screenplay', 'Club Kid', null, 47.39),
  ('Best Casting', 'The Odyssey', null, 96.37),
  ('Best Casting', 'La Bola Negra', null, 95.59),
  ('Best Casting', 'Wild Horse Nine', null, 87.35),
  ('Best Casting', 'The Debut', null, 73.82),
  ('Best Casting', 'The Invite', null, 43.92),
  ('Best Cinematography', 'The Odyssey', null, 98.01),
  ('Best Cinematography', 'La Bola Negra', null, 94.98),
  ('Best Cinematography', 'Dune: Part Three', null, 92.78),
  ('Best Cinematography', 'Project Hail Mary', null, 76.88),
  ('Best Cinematography', 'Werwulf', null, 67.26),
  ('Best Costume Design', 'The Odyssey', null, 97.83),
  ('Best Costume Design', 'La Bola Negra', null, 93.92),
  ('Best Costume Design', 'Dune: Part Three', null, 90.23),
  ('Best Costume Design', 'Sense and Sensibility', null, 81.22),
  ('Best Costume Design', 'Werwulf', null, 66.12),
  ('Best Film Editing', 'The Odyssey', null, 96.71),
  ('Best Film Editing', 'La Bola Negra', null, 94.38),
  ('Best Film Editing', 'Wild Horse Nine', null, 79.64),
  ('Best Film Editing', 'You Can See Everything', null, 79.53),
  ('Best Film Editing', 'Project Hail Mary', null, 59.60),
  ('Best Makeup and Hairstyling', 'Werwulf', null, 95.12),
  ('Best Makeup and Hairstyling', 'The Odyssey', null, 94.46),
  ('Best Makeup and Hairstyling', 'Digger', null, 85.70),
  ('Best Makeup and Hairstyling', 'Dune: Part Three', null, 83.26),
  ('Best Makeup and Hairstyling', 'Clayface', null, 50.55),
  ('Best Production Design', 'The Odyssey', null, 98.14),
  ('Best Production Design', 'Dune: Part Three', null, 94.88),
  ('Best Production Design', 'La Bola Negra', null, 92.21),
  ('Best Production Design', 'Project Hail Mary', null, 85.70),
  ('Best Production Design', 'Werwulf', null, 59.07),
  ('Best Score', 'The Odyssey', null, 97.29),
  ('Best Score', 'La Bola Negra', null, 94.16),
  ('Best Score', 'Project Hail Mary', null, 86.80),
  ('Best Score', 'Dune: Part Three', null, 76.30),
  ('Best Score', 'Disclosure Day', null, 68.40),
  ('Best Song', 'La Bola Negra', 'La Nieve', 97.56),
  ('Best Song', 'The Debut', 'This City May Have Chewed Me Up', 95.01),
  ('Best Song', 'Toy Story 5', 'I Knew It, I Knew You', 88.80),
  ('Best Song', 'The Odyssey', 'When I’m Home', 61.00),
  ('Best Song', 'By Any Means', 'By Any Means', 51.02),
  ('Best Sound', 'The Odyssey', null, 98.06),
  ('Best Sound', 'Project Hail Mary', null, 96.46),
  ('Best Sound', 'Dune: Part Three', null, 95.66),
  ('Best Sound', 'La Bola Negra', null, 84.80),
  ('Best Sound', 'Disclosure Day', null, 41.26),
  ('Best Visual Effects', 'Project Hail Mary', null, 97.03),
  ('Best Visual Effects', 'Dune: Part Three', null, 96.00),
  ('Best Visual Effects', 'The Odyssey', null, 92.69),
  ('Best Visual Effects', 'Godzilla Minus Zero', null, 92.11),
  ('Best Visual Effects', 'Wildwood', null, 54.17),
  ('Best Animated Feature', 'Wildwood', null, 98.20),
  ('Best Animated Feature', 'Toy Story 5', null, 95.62),
  ('Best Animated Feature', 'Iron Boy', null, 73.74),
  ('Best Animated Feature', 'Hoppers', null, 73.06),
  ('Best Animated Feature', 'Tangles', null, 61.73),
  ('Best Documentary Feature', 'Naza', null, 96.74),
  ('Best Documentary Feature', 'Once Upon a Time in Harlem', null, 95.10),
  ('Best Documentary Feature', 'You Can See Everything', null, 93.25),
  ('Best Documentary Feature', 'American Doctor', null, 77.26),
  ('Best Documentary Feature', 'Musk', null, 46.57),
  ('Best International Film', 'La Bola Negra', null, 97.44),
  ('Best International Film', 'All of a Sudden', null, 95.37),
  ('Best International Film', 'Fjord', null, 86.81),
  ('Best International Film', 'Possible Love', null, 78.35),
  ('Best International Film', 'Rose', null, 52.95)
  ) as t(category, film_title, performer_name, nom_odds)
));

-- Should be 21 categories x 5 rows, nothing else.
select category, count(*) as nominees, min(nom_odds) as lowest, max(nom_odds) as highest
from gold_derby_odds where season = '2027' group by category order by max(nom_odds) desc;
