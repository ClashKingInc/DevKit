-- +goose Up
-- Migrate persisted settings once. Runtime readers use only the current contract.
-- Existing role assignments and published button identities are unchanged.
-- +goose StatementBegin
CREATE FUNCTION pg_temp.current_ticket_settings(saved jsonb, guild text, resolve_welcome boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  result jsonb;
  key text;
  value jsonb;
  intro jsonb;
  template jsonb;
BEGIN
  IF jsonb_typeof(saved) <> 'object' THEN
    RAISE EXCEPTION 'Invalid stored ticket settings for server %', guild;
  END IF;
  result := jsonb_build_object(
    'private_thread', COALESCE(NULLIF(saved->'private_thread', 'null'::jsonb), 'false'::jsonb),
    'th_min', COALESCE(NULLIF(saved->'th_min', 'null'::jsonb), '0'::jsonb),
    'hero_min_percent', COALESCE(NULLIF(saved->'hero_min_percent', 'null'::jsonb), '0'::jsonb),
    'naming', COALESCE(NULLIF(saved->'naming', 'null'::jsonb), '""'::jsonb),
    'account_apply', COALESCE(NULLIF(saved->'account_apply', 'null'::jsonb), 'false'::jsonb)
  );
  FOREACH key IN ARRAY ARRAY['mod_role','no_ping_mod_role','roles_to_add','roles_to_remove'] LOOP
    value := saved->key;
    IF value IS NULL OR value = 'null'::jsonb THEN value := '[]'::jsonb;
    ELSIF jsonb_typeof(value) IN ('string','number') THEN value := jsonb_build_array(value #>> '{}');
    ELSIF jsonb_typeof(value) = 'array' THEN
      IF EXISTS(SELECT 1 FROM jsonb_array_elements(value) e WHERE jsonb_typeof(e) NOT IN ('string','number')) THEN RAISE EXCEPTION 'Invalid ticket role entry for server %',guild; END IF;
      SELECT COALESCE(jsonb_agg(to_jsonb(e #>> '{}')), '[]'::jsonb) INTO value FROM jsonb_array_elements(value) e;
    ELSE RAISE EXCEPTION 'Invalid ticket role list % for server %', key, guild;
    END IF;
    result := result || jsonb_build_object(key, value);
  END LOOP;
  value := saved->'application_questions';
  IF value IS NULL OR value = 'null'::jsonb THEN
    value := saved->'questions';
    IF value IS NULL OR value = 'null'::jsonb THEN value := '[]'::jsonb;
    ELSIF jsonb_typeof(value) = 'string' THEN value := jsonb_build_array(value);
    END IF;
    IF jsonb_typeof(value) <> 'array' OR EXISTS(SELECT 1 FROM jsonb_array_elements(value) e WHERE jsonb_typeof(e) <> 'string') THEN RAISE EXCEPTION 'Invalid ticket questions for server %',guild; END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id','migrated-' || (ordinality - 1)::text, 'label',entry #>> '{}',
      'order',ordinality - 1, 'type','text', 'required',true, 'options','[]'::jsonb
    ) ORDER BY ordinality), '[]'::jsonb) INTO value
    FROM jsonb_array_elements(value) WITH ORDINALITY q(entry,ordinality)
    WHERE btrim(entry #>> '{}') <> '';
  END IF;
  result := result || jsonb_build_object('application_questions',value);
  intro := saved->'opening_message';
  IF intro IS NULL OR intro = 'null'::jsonb THEN
    IF resolve_welcome AND NULLIF(saved->>'new_message','') IS NOT NULL AND saved->>'new_message' <> 'disabled' THEN
      SELECT data INTO template FROM server_custom_embeds
      WHERE server_id=guild AND name=saved->>'new_message';
      IF template IS NULL THEN
        -- The referenced template was deleted; there is no content to migrate.
        -- Use the normal welcome message, but report the repair to the operator.
        RAISE NOTICE 'Removed broken ticket welcome reference for server %',guild;
        RETURN result;
      END IF;
      IF jsonb_typeof(template->'messages') = 'array' THEN
        SELECT COALESCE(jsonb_agg(embed), '[]'::jsonb) INTO value
        FROM jsonb_array_elements(template->'messages') m,
          LATERAL jsonb_array_elements(m->'data'->'embeds') embed;
      ELSE value := template->'embeds'; END IF;
      IF jsonb_typeof(value) <> 'array' THEN RAISE EXCEPTION 'Invalid ticket welcome template for server %',guild; END IF;
      intro := jsonb_build_object('embeds',value);
    END IF;
  END IF;
  IF intro IS NOT NULL AND intro <> 'null'::jsonb THEN result := result || jsonb_build_object('opening_message',intro); END IF;
  RETURN result;
END;
$$;
-- +goose StatementEnd

UPDATE ticket_panels p
SET data = p.data || COALESCE((
  SELECT jsonb_object_agg(e.key,pg_temp.current_ticket_settings(e.value,p.server_id))
  FROM jsonb_each(p.data) e WHERE e.key LIKE '%\_settings' ESCAPE '\'
),'{}'::jsonb);

-- Already accepted work retains the same behavior after the reader switches.
UPDATE ticket_runtime_operations op
SET context=jsonb_set(op.context,'{settings}',pg_temp.current_ticket_settings(op.context->'settings',op.server_id,false))
WHERE jsonb_typeof(op.context->'settings')='object';

-- +goose Down
-- Obsolete fields are intentionally not recreated. Restore a reviewed backup
-- before rolling back to a runtime that requires the obsolete settings shape.
SELECT 1;
