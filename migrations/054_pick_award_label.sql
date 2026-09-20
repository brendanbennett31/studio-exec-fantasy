-- Remembers HOW a festival-award pick got resolved. A Festival Futures
-- placeholder like "TIFF - People's Choice Award" used to just vanish into
-- the winning film's title when resolved (title was cleared), so nothing
-- on the slate said why a film like La Bola Negra was there. award_label
-- keeps the original placeholder title so the UI can show
-- "La Bola Negra (TIFF - People's Choice Award)". Purely descriptive --
-- nothing reads it for scoring or eligibility.
alter table league_picks add column if not exists award_label text;

-- Backfill La Bola Negra (pick 69, resolved by migration 053).
update league_picks
set award_label = 'TIFF - People''s Choice Award'
where id = 69 and award_label is null;
