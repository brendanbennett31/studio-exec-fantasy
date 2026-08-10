-- Data repair: a batch of 24 universe_films rows got auto-locked on
-- 2026-08-03/2026-08-04 (no_change_days hit exactly 3 on the same one or
-- two days), right in the window where the deployed Apps Script project's
-- copy of the box office scraper had drifted from the correct source (see
-- the extractDomesticBO incident). Several of the affected titles are
-- still-in-wide-release blockbusters (Spider-Man: Brand New Day, The
-- Odyssey, Toy Story 5, Moana, The Mandalorian and Grogu) that would not
-- realistically plateau together on the same real-world day -- this is a
-- bug signature, not 24 films genuinely finishing their theatrical run at
-- once.
--
-- Deliberately NOT touching the other locked rows (no_change_days = 0,
-- last_check_date null) -- those look like legitimate manual locks an
-- admin set once a film's run actually finished, unrelated to this bug.
update universe_films
set locked = false,
    no_change_days = 0
where locked = true
  and no_change_days = 3
  and last_check_date in ('2026-08-03', '2026-08-04');
