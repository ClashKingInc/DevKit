-- +goose Up
SET LOCAL lock_timeout = '5s';

-- Publish both public distributions from one source scan. NULL locations and
-- out-of-range member counts retain their existing API buckets.
CREATE MATERIALIZED VIEW public.api_clan_distribution_counts AS
WITH dimensions AS (
    SELECT
        location_id,
        CASE WHEN member_count BETWEEN 1 AND 50
            THEN 1 + ((member_count - 1) / 5) * 5
            ELSE member_count END AS min_members,
        CASE WHEN member_count BETWEEN 1 AND 50
            THEN 5 + ((member_count - 1) / 5) * 5
            ELSE member_count END AS max_members
    FROM public.basic_clan
)
SELECT
    CASE WHEN GROUPING(location_id) = 0 THEN 'location' ELSE 'members' END::text AS dimension,
    CASE WHEN GROUPING(location_id) = 0 THEN location_id ELSE min_members END AS bucket,
    CASE WHEN GROUPING(location_id) = 0 THEN NULL::integer ELSE max_members END AS upper_bound,
    count(*)::bigint AS clan_count,
    transaction_timestamp() AS refreshed_at
FROM dimensions
GROUP BY GROUPING SETS ((location_id), (min_members, max_members));

CREATE UNIQUE INDEX api_clan_distribution_counts_key
    ON public.api_clan_distribution_counts (dimension, bucket) NULLS NOT DISTINCT;

COMMENT ON MATERIALIZED VIEW public.api_clan_distribution_counts IS
    'Exact clan location and member-bin distributions, refreshed by Tracking statistics maintenance; API reads the last completed publication.';

-- +goose Down
DROP MATERIALIZED VIEW public.api_clan_distribution_counts;
