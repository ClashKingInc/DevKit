\set ON_ERROR_STOP on
\if :{?scope}
\else
\echo 'Set scope to current, previous, current_previous, or all.'
\quit 2
\endif

SELECT :'scope' IN ('current','previous','current_previous','all') AS valid_scope \gset
\if :valid_scope
\else
\echo 'scope must be current, previous, current_previous, or all.'
\quit 2
\endif

BEGIN;
CALL public.reconcile_cwl_season_statistics(
    CASE :'scope'
        WHEN 'current' THEN ARRAY[to_char(current_timestamp AT TIME ZONE 'UTC','YYYY-MM')]
        WHEN 'previous' THEN ARRAY[to_char((current_timestamp AT TIME ZONE 'UTC') - INTERVAL '1 month','YYYY-MM')]
        WHEN 'current_previous' THEN ARRAY[
            to_char(current_timestamp AT TIME ZONE 'UTC','YYYY-MM'),
            to_char((current_timestamp AT TIME ZONE 'UTC') - INTERVAL '1 month','YYYY-MM')
        ]
        WHEN 'all' THEN NULL
    END
);
COMMIT;

TABLE public.cwl_season_statistics ORDER BY season DESC,cwl_league_id,war_size;
