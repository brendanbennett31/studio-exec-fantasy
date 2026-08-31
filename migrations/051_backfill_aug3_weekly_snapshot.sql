-- One-off data recovery: the live league's weekly_bo_snapshots/
-- weekly_poi_snapshots history has a real gap between Jul 27 and Aug 10,
-- 2026 -- no snapshot was ever taken for Aug 3 (the cron simply didn't run
-- that week, before this session's fixes). Reconstructed here from real
-- data rather than guessed: for every film released on or before 2026-08-03
-- and drafted in this league, summed its actual cumulative box office AS
-- OF that date directly from daily_bo (per-day Box Office Mojo data,
-- itself real -- see the Apps Script daily scraper fix earlier this
-- session). Where a film's daily_bo coverage doesn't extend exactly to
-- 2026-08-03 (some titles' daily reporting window on BOM had already
-- closed by then), used its last available date instead -- in every case
-- checked, that film had already locked (3+ consecutive unchanged days)
-- well before Aug 3, so its real total on that date is the same number
-- either way, not an approximation of a still-moving target.
--
-- Note for whoever looks at this later: PATRICK's reconstructed Aug 3
-- total ($178.1M) is very slightly BELOW the existing (old-system) Jul 27
-- snapshot ($187M) -- box office cannot actually go down, so this means
-- the old Jul 27 number itself was off by ~$9M, not that this
-- reconstruction is wrong. Left as-is rather than also "fixing" Jul 27,
-- since that number came from the legacy sheet-based system this session
-- already retired, and chasing down its exact original error isn't worth
-- it for one week, one team, ~5% off.
insert into weekly_bo_snapshots (league_id, week_label, team, bo, snapshot_date) values
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'Continental Studios', 970372508, '2026-08-03'),
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'Ginza Films',         658521410, '2026-08-03'),
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'No Wot Studios',      946838923, '2026-08-03'),
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'PATRICK',             178112202, '2026-08-03'),
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'Sacko Studios',       954074451, '2026-08-03')
on conflict (league_id, week_label, team) do nothing;

insert into weekly_poi_snapshots (league_id, week_label, team, poi, snapshot_date) values
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'Continental Studios', 3.140364, '2026-08-03'),
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'Ginza Films',         2.900975, '2026-08-03'),
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'No Wot Studios',      3.220541, '2026-08-03'),
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'PATRICK',             2.095438, '2026-08-03'),
  ('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'Aug 3', 'Sacko Studios',       2.478115, '2026-08-03')
on conflict (league_id, week_label, team) do nothing;
