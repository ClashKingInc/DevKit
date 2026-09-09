-- +goose Up
-- Apply before deploying the Legend-only composition writer. Raw Ranked battles
-- retain their hash/share code but no longer require a materialized composition.
SET LOCAL lock_timeout = '5s';
ALTER TABLE public.battles_ranked
    DROP CONSTRAINT battles_ranked_army_hash_fkey,
    DROP CONSTRAINT battles_ranked_share_code_hash_fkey;

-- Composition identity remains immutable. Permit a separately reviewed cleanup
-- of unused rows; existing family foreign keys and no-truncate guard remain.
DROP TRIGGER army_compositions_immutable ON public.army_compositions;
CREATE TRIGGER army_compositions_immutable BEFORE UPDATE ON public.army_compositions
    FOR EACH ROW EXECUTE FUNCTION public.reject_army_identity_mutation();

-- +goose Down
-- This intentionally fails safely if Ranked-only hashes lack compositions.
-- Restore the old writer and backfill those compositions before rolling back.
SET LOCAL lock_timeout = '5s';
ALTER TABLE public.battles_ranked
    ADD CONSTRAINT battles_ranked_army_hash_fkey FOREIGN KEY (army_hash)
        REFERENCES public.army_compositions(army_hash),
    ADD CONSTRAINT battles_ranked_share_code_hash_fkey FOREIGN KEY (army_hash, share_code)
        REFERENCES public.army_compositions(army_hash, normalized_share_code);
DROP TRIGGER army_compositions_immutable ON public.army_compositions;
CREATE TRIGGER army_compositions_immutable BEFORE UPDATE OR DELETE ON public.army_compositions
    FOR EACH ROW EXECUTE FUNCTION public.reject_army_identity_mutation();
