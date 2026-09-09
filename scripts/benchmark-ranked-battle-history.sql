-- Run only against a disposable migrated fixture.
-- The first plan serves all perspectives for one player; the second scans only
-- attacker rows so a physical battle stored twice contributes once.
SET enable_seqscan = off;
EXPLAIN (ANALYZE, COSTS OFF, BUFFERS)
SELECT * FROM public.battles_ranked
WHERE player_tag = '#2PP' AND battle_time >= now() - interval '30 days'
ORDER BY battle_time DESC;

EXPLAIN (ANALYZE, COSTS OFF, BUFFERS)
SELECT count(*) FROM public.battles_ranked
WHERE direction = 'attack' AND battle_time >= now() - interval '30 days';
RESET enable_seqscan;
