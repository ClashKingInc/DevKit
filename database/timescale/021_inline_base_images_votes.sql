-- +goose Up
-- Lock source tables before copying so concurrent old writers cannot be lost.
LOCK TABLE public.bases, public.base_images, public.base_votes IN ACCESS EXCLUSIVE MODE;
ALTER TABLE public.bases ADD COLUMN images text[] NOT NULL DEFAULT '{}',
    ADD COLUMN votes jsonb NOT NULL DEFAULT '{}';
UPDATE public.bases b SET images=x.images FROM (
    SELECT base_id,array_agg(i.image_url ORDER BY p.position) images
    FROM (SELECT base_id,max(position) last_position FROM public.base_images GROUP BY base_id) s
    CROSS JOIN LATERAL generate_series(1,s.last_position) p(position)
    LEFT JOIN public.base_images i USING(base_id,position) GROUP BY base_id
) x WHERE b.id=x.base_id;
UPDATE public.bases b SET votes=x.votes FROM (
    SELECT base_id,jsonb_object_agg(user_id,jsonb_build_object('vote',vote,'updatedAt',updated_at)) votes
    FROM public.base_votes GROUP BY base_id
) x WHERE b.id=x.base_id;

-- Null array slots preserve positions during partial legacy-image staging.
-- +goose StatementBegin
CREATE FUNCTION public.base_images_valid(value text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
 SELECT cardinality(value)<=4 AND (cardinality(value)=0 OR (array_ndims(value)=1 AND array_lower(value,1)=1))
 AND NOT EXISTS(SELECT 1 FROM unnest(value) image WHERE image IS NOT NULL AND image !~ '^https://api[.]clashk[.]ing/v2/media/[A-Za-z0-9][A-Za-z0-9._-]*$')
 AND (SELECT count(image)=count(DISTINCT image) FROM unnest(value) image)
$$;
CREATE FUNCTION public.base_votes_valid(value jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE entry record; parsed timestamptz;
BEGIN
 IF jsonb_typeof(value)<>'object' THEN RETURN false; END IF;
 FOR entry IN SELECT * FROM jsonb_each(value) LOOP
  IF entry.key !~ '^[0-9]+$' OR jsonb_typeof(entry.value)<>'object'
     OR NOT (entry.value ? 'vote' AND entry.value ? 'updatedAt')
     OR entry.value->'vote' NOT IN ('1'::jsonb,'-1'::jsonb)
     OR jsonb_typeof(entry.value->'updatedAt')<>'string' THEN RETURN false; END IF;
  BEGIN parsed:=(entry.value->>'updatedAt')::timestamptz;
  EXCEPTION WHEN others THEN RETURN false; END;
 END LOOP;
 RETURN true;
END $$;
-- +goose StatementEnd
ALTER TABLE public.bases ADD CONSTRAINT bases_images_check CHECK(public.base_images_valid(images)),
 ADD CONSTRAINT bases_votes_check CHECK(public.base_votes_valid(votes));
DROP VIEW public.base_public_counts;
CREATE VIEW public.base_public_counts AS SELECT id base_id,
 (SELECT count(*) FROM jsonb_object_keys(downloads)) download_count,
 (SELECT count(*) FROM jsonb_each(votes) v WHERE v.value->>'vote'='1') upvote_count,
 (SELECT count(*) FROM jsonb_each(votes) v WHERE v.value->>'vote'='-1') downvote_count
 FROM public.bases;
DROP TABLE public.base_images;
DROP TABLE public.base_votes;

-- +goose Down
-- Require coordinated reader/writer rollback; do not silently discard inline data.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION '021 requires an explicit data-preserving rollback; do not drop inline images or votes'; END $$;
-- +goose StatementEnd
