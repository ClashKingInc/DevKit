#!/usr/bin/env bash
# Exercise the actual published baseline -> pending SQL upgrade, not a helper mock.
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999991001','Duplicate ticket fixture');
INSERT INTO ticket_panel(id,server_id,name,description) VALUES('00000000-0000-4000-8000-000000000001','999999999999991001','Recruit','');
INSERT INTO ticket_panel_buttons(id,panel_id,server_id,custom_id,label) VALUES('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','999999999999991001','Recruit_0','First');
INSERT INTO ticket_panels(server_id,name,components,data) VALUES('999999999999991001','Recruit','[{"type":2,"custom_id":"Recruit_0","label":"First","style":1},{"type":2,"custom_id":"Recruit_0","label":"Second","style":2}]','{"Recruit_0_settings":{"questions":["Player tag?"],"account_apply":true},"unrelated":"keep"}');
INSERT INTO tickets(id,server_id,channel_id,panel_id) VALUES('00000000-0000-4000-8000-000000000003','999999999999991001','999999999999991002','00000000-0000-4000-8000-000000000001');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE p record; first_action text; second_action text;
BEGIN
 SELECT * INTO STRICT p FROM ticket_panels WHERE server_id='999999999999991001' AND name='Recruit';
 IF jsonb_array_length(p.components)<>2 OR p.components->0->>'label'<>'First' OR p.components->1->>'label'<>'Second' OR p.components->1->>'style'<>'2' THEN RAISE EXCEPTION 'Visual buttons changed'; END IF;
 first_action=p.components->0->>'custom_id';second_action=p.components->1->>'custom_id';
 IF first_action=second_action OR p.components->0->>'id'<>'00000000-0000-4000-8000-000000000002' THEN RAISE EXCEPTION 'Canonical identity not preserved/split'; END IF;
 IF p.data->(first_action||'_settings') IS DISTINCT FROM p.data->(second_action||'_settings') OR p.data->(first_action||'_settings')->>'account_apply'<>'true' THEN RAISE EXCEPTION 'Shared action settings lost'; END IF;
 IF p.data->'legacy_button_ids'->>'Recruit_0'<>first_action OR p.data->>'unrelated'<>'keep' THEN RAISE EXCEPTION 'Legacy alias or unrelated data lost'; END IF;
 IF NOT EXISTS(SELECT 1 FROM tickets WHERE id='00000000-0000-4000-8000-000000000003' AND panel_id=p.id) THEN RAISE EXCEPTION 'Existing ticket identity lost'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
printf 'PASS ticket upgrade: distinct visual buttons retained, shared settings cloned, canonical IDs unique, legacy alias and ticket reference preserved.\n'
