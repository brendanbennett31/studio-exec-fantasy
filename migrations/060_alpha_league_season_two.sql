-- Label the ALPHA (experimental 2027) league "Season 2" in its header.
-- season_number is display-only (league.html: "Season N • 2027/28"); the
-- functional `season` column is untouched. Scoped to this league's id and
-- guarded by name/season so it cannot touch any other league (2026 stays
-- Season 1).
update leagues
set season_number = 2
where id = 'dafbb0fd-7b29-41ac-8b15-dd002cdc6db7'
  and season = '2027' and name ilike '%alpha%';

select id, name, season, season_number from leagues
where id = 'dafbb0fd-7b29-41ac-8b15-dd002cdc6db7';
