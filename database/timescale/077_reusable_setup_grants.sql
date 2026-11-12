-- +goose Up
-- Bot setup links can start independent browser sessions during their lifetime.
-- App grants remain single-use under the API's locked grant transaction.
ALTER TABLE public.dashboard_scoped_sessions
    DROP CONSTRAINT dashboard_scoped_sessions_grant_id_key;
CREATE INDEX dashboard_scoped_sessions_grant_id_idx
    ON public.dashboard_scoped_sessions (grant_id);

-- +goose Down
-- Keep the newest session per grant when restoring the old one-session model.
DELETE FROM public.dashboard_scoped_sessions AS older
USING public.dashboard_scoped_sessions AS newer
WHERE older.grant_id = newer.grant_id
    AND older.id < newer.id;
DROP INDEX public.dashboard_scoped_sessions_grant_id_idx;
ALTER TABLE public.dashboard_scoped_sessions
    ADD CONSTRAINT dashboard_scoped_sessions_grant_id_key UNIQUE (grant_id);
