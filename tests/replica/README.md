# Local replica

Rebuilds the live schema locally (export with tests/export_schema.sql -> sef_schema.csv), runs PostgREST + gateway.py, and plays whole seasons: sim_draft.py N TAG, sim_season.py TAG END, sim_oscars.py, sim_attacks.py, sim_attacks2.py (commissioner powers, draft races, junk input). apply.py applies one new migration to a running replica. Needs psql (SEF_PSQL), a Postgres on 127.0.0.1:54329, and PostgREST (brew install postgrest). seed.py expects seed/*.json pulled from the public API.
