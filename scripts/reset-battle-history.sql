-- Explicit operator-only reset. Stop battle-log ingestion before running this.
-- No CASCADE and no trigger disabling: retained families prevent this reset.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
LOCK TABLE public.battles_ranked IN ACCESS EXCLUSIVE MODE;
LOCK TABLE public.army_compositions IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.army_families, public.army_family_members,
    public.army_family_daily_stats, public.legend_daily_stats,
    public.league_hitrate_stats IN SHARE MODE;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.army_families)
        OR EXISTS (SELECT 1 FROM public.army_family_members)
        OR EXISTS (SELECT 1 FROM public.army_family_daily_stats)
        OR EXISTS (SELECT 1 FROM public.legend_daily_stats)
        OR EXISTS (SELECT 1 FROM public.league_hitrate_stats) THEN
        RAISE EXCEPTION 'Reset refused: retained families or battle-derived aggregates require a separate reconciliation plan';
    END IF;
END $$;
TRUNCATE TABLE public.battles_ranked;
DELETE FROM public.army_compositions;
COMMIT;
