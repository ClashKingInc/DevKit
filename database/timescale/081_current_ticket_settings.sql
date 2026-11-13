-- +goose Up
-- Migrate persisted settings once. Runtime readers use only the current contract.
-- Existing role assignments and published button identities are unchanged.
-- +goose StatementBegin
-- Discord and the API count UTF-16 code units, while PostgreSQL counts Unicode
-- characters. Never cut a supplementary character in half at a Discord limit.
CREATE FUNCTION pg_temp.ticket_prefix(value text, max_units integer)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT COALESCE(string_agg(ch, '' ORDER BY n), '')
  FROM (
    SELECT n, substr(value, n, 1) AS ch,
      sum(CASE WHEN octet_length(substr(value, n, 1)) = 4 THEN 2 ELSE 1 END)
        OVER (ORDER BY n) AS units
    FROM generate_series(1, char_length(value)) AS n
  ) chars WHERE units <= max_units;
$$;

CREATE FUNCTION pg_temp.ticket_label(value text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT pg_temp.ticket_prefix(regexp_replace(value, '^[[:space:]]+|[[:space:]]+$', '', 'g'),45);
$$;

CREATE FUNCTION pg_temp.ticket_units(value text)
RETURNS integer LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT COALESCE(sum(CASE WHEN octet_length(substr(value,n,1)) = 4 THEN 2 ELSE 1 END),0)::integer
  FROM generate_series(1,char_length(value)) AS n;
$$;

CREATE FUNCTION pg_temp.ticket_url(value jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  parts text[];
  url text;
BEGIN
  IF jsonb_typeof(value) IS DISTINCT FROM 'string' THEN RETURN NULL; END IF;
  url := value #>> '{}';
  -- Keep ordinary HTTP(S) hostnames and IPv4 addresses, never credentials,
  -- malformed ports, attachment references, or unsupported host syntax.
  parts := regexp_match(url, '^https?://([a-z0-9][a-z0-9._-]*)(:([0-9]{1,5}))?([/?#][^[:space:]]*)?$', 'i');
  IF parts IS NULL OR (parts[3] IS NOT NULL AND parts[3]::integer > 65535) THEN RETURN NULL; END IF;
  IF parts[1] ~ '^[0-9.]+$' THEN
    BEGIN PERFORM parts[1]::inet; EXCEPTION WHEN invalid_text_representation THEN RETURN NULL; END;
  END IF;
  RETURN url;
END;
$$;

-- Keep only outbound Discord embed fields. Saved editor payloads may contain
-- read-only proxies, attachment URLs, or nulls that the new contract rejects.
CREATE FUNCTION pg_temp.ticket_embed(saved jsonb, guild text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  result jsonb := '{}'::jsonb;
  part jsonb;
  fields jsonb := '[]'::jsonb;
  field jsonb;
  item jsonb;
  key text;
  link text;
  maximum integer;
BEGIN
  IF jsonb_typeof(saved) <> 'object' THEN
    RAISE NOTICE 'Skipped invalid ticket welcome embed for server %', guild;
    RETURN NULL;
  END IF;
  FOREACH key IN ARRAY ARRAY['title','description'] LOOP
    IF jsonb_typeof(saved->key) = 'string' THEN
      maximum := CASE key WHEN 'title' THEN 256 WHEN 'description' THEN 4096 ELSE 100 END;
      result := result || jsonb_build_object(key, pg_temp.ticket_prefix(saved->>key, maximum));
    END IF;
  END LOOP;
  IF jsonb_typeof(saved->'timestamp') = 'string' THEN
    BEGIN
      result := result || jsonb_build_object('timestamp',to_char((saved->>'timestamp')::timestamptz AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
      RAISE NOTICE 'Omitted invalid ticket embed timestamp for server %',guild;
    END;
  END IF;
  IF jsonb_typeof(saved->'color') = 'number' THEN
    IF (saved->>'color')::numeric BETWEEN 0 AND 16777215 AND trunc((saved->>'color')::numeric) = (saved->>'color')::numeric THEN
      result := result || jsonb_build_object('color', saved->'color');
    ELSE RAISE NOTICE 'Omitted invalid ticket embed color for server %',guild; END IF;
  END IF;
  link := pg_temp.ticket_url(saved->'url');
  IF link IS NOT NULL THEN result := result || jsonb_build_object('url', link);
  ELSIF saved ? 'url' AND saved->'url' <> 'null'::jsonb THEN RAISE NOTICE 'Omitted invalid ticket embed URL for server %', guild; END IF;
  FOREACH key IN ARRAY ARRAY['image','thumbnail'] LOOP
    part := saved->key;
    IF jsonb_typeof(part) = 'object' THEN
      link := COALESCE(pg_temp.ticket_url(part->'url'), pg_temp.ticket_url(part->'proxy_url'));
      IF link IS NOT NULL THEN result := result || jsonb_build_object(key, jsonb_build_object('url',link));
      ELSE RAISE NOTICE 'Omitted unavailable ticket embed % for server %', key, guild; END IF;
    END IF;
  END LOOP;
  FOREACH key IN ARRAY ARRAY['author','footer'] LOOP
    part := saved->key;
    IF jsonb_typeof(part) = 'object' AND jsonb_typeof(part->CASE key WHEN 'author' THEN 'name' ELSE 'text' END) = 'string' THEN
      item := jsonb_build_object(CASE key WHEN 'author' THEN 'name' ELSE 'text' END,
        pg_temp.ticket_prefix(part->>CASE key WHEN 'author' THEN 'name' ELSE 'text' END, CASE key WHEN 'author' THEN 256 ELSE 2048 END));
      link := COALESCE(pg_temp.ticket_url(part->'icon_url'), pg_temp.ticket_url(part->'proxy_icon_url'));
      IF link IS NOT NULL THEN item := item || jsonb_build_object('icon_url',link);
      ELSIF part ? 'icon_url' AND part->'icon_url' <> 'null'::jsonb THEN RAISE NOTICE 'Omitted invalid ticket embed icon for server %',guild; END IF;
      IF key = 'author' THEN
        link := pg_temp.ticket_url(part->'url');
        IF link IS NOT NULL THEN item := item || jsonb_build_object('url',link);
        ELSIF part ? 'url' AND part->'url' <> 'null'::jsonb THEN RAISE NOTICE 'Omitted invalid ticket embed author URL for server %',guild; END IF;
      END IF;
      result := result || jsonb_build_object(key,item);
    END IF;
  END LOOP;
  IF jsonb_typeof(saved->'fields') = 'array' THEN
    FOR field IN SELECT value FROM jsonb_array_elements(saved->'fields') WITH ORDINALITY x(value,n) WHERE n <= 25 ORDER BY n LOOP
      IF jsonb_typeof(field) = 'object' AND jsonb_typeof(field->'name') = 'string' AND jsonb_typeof(field->'value') = 'string'
        AND field->>'name' ~ '[^[:space:]]' AND field->>'value' ~ '[^[:space:]]' THEN
        item := jsonb_build_object('name',pg_temp.ticket_prefix(field->>'name',256),'value',pg_temp.ticket_prefix(field->>'value',1024));
        IF jsonb_typeof(field->'inline') = 'boolean' THEN item := item || jsonb_build_object('inline',field->'inline'); END IF;
        fields := fields || jsonb_build_array(item);
      ELSE RAISE NOTICE 'Skipped invalid ticket embed field for server %',guild; END IF;
    END LOOP;
    IF jsonb_array_length(fields) > 0 THEN result := result || jsonb_build_object('fields',fields); END IF;
  END IF;
  IF COALESCE(length(result->>'title'),0) + COALESCE(length(result->>'description'),0)
    + COALESCE(length(result->'author'->>'name'),0) + COALESCE(length(result->'footer'->>'text'),0) = 0
    AND NOT (result ? 'image' OR result ? 'thumbnail' OR result ? 'fields') THEN
    RAISE NOTICE 'Skipped empty ticket welcome embed for server %',guild;
    RETURN NULL;
  END IF;
  RETURN result;
END;
$$;

-- Migrate saved template text, canonical embeds, and link buttons. Interactive
-- IDs from legacy saved templates have no current handler and must not be sent.
CREATE FUNCTION pg_temp.ticket_welcome(saved jsonb, guild text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  messages jsonb;
  message jsonb;
  embed jsonb;
  cleaned jsonb;
  row jsonb;
  button jsonb;
  item jsonb;
  emoji jsonb;
  embeds jsonb := '[]'::jsonb;
  components jsonb := '[]'::jsonb;
  buttons jsonb;
  result jsonb := '{}'::jsonb;
  content text;
  link text;
  text_units integer := 0;
BEGIN
  IF jsonb_typeof(saved) <> 'object' THEN RETURN NULL; END IF;
  messages := CASE WHEN jsonb_typeof(saved->'messages') = 'array' THEN saved->'messages' ELSE jsonb_build_array(jsonb_build_object('data',saved)) END;
  FOR message IN SELECT value->'data' FROM jsonb_array_elements(messages) WITH ORDINALITY x(value,n) ORDER BY n LOOP
    IF jsonb_typeof(message) <> 'object' THEN CONTINUE; END IF;
    IF jsonb_typeof(message->'content') = 'string' AND message->>'content' ~ '[^[:space:]]' THEN
      content := concat_ws(E'\n\n',content,message->>'content');
    END IF;
    IF jsonb_typeof(message->'embeds') = 'array' THEN
      FOR embed IN SELECT value FROM jsonb_array_elements(message->'embeds') WITH ORDINALITY x(value,n) ORDER BY n LOOP
        cleaned := pg_temp.ticket_embed(embed,guild);
        IF cleaned IS NOT NULL THEN
          text_units := text_units + pg_temp.ticket_units(COALESCE(cleaned->>'title',''))
            + pg_temp.ticket_units(COALESCE(cleaned->>'description',''))
            + pg_temp.ticket_units(COALESCE(cleaned->'author'->>'name',''))
            + pg_temp.ticket_units(COALESCE(cleaned->'footer'->>'text',''));
          SELECT text_units + COALESCE(sum(pg_temp.ticket_units(field->>'name') + pg_temp.ticket_units(field->>'value')),0)
            INTO text_units FROM jsonb_array_elements(COALESCE(cleaned->'fields','[]'::jsonb)) field;
          embeds := embeds || jsonb_build_array(cleaned);
        END IF;
      END LOOP;
    END IF;
    IF jsonb_typeof(message->'components') = 'array' THEN
      FOR row IN SELECT value FROM jsonb_array_elements(message->'components') WITH ORDINALITY x(value,n) ORDER BY n LOOP
        buttons := '[]'::jsonb;
        IF jsonb_typeof(row->'components') <> 'array' THEN CONTINUE; END IF;
        FOR button IN SELECT value FROM jsonb_array_elements(row->'components') WITH ORDINALITY x(value,n) ORDER BY n LOOP
          link := pg_temp.ticket_url(button->'url');
          IF button->'type' IS DISTINCT FROM '2'::jsonb OR button->'style' IS DISTINCT FROM '5'::jsonb OR link IS NULL THEN
            RAISE NOTICE 'Omitted unsupported ticket welcome action for server %',guild;
            CONTINUE;
          END IF;
          item := jsonb_build_object('type',2,'style',5,'url',link);
          IF jsonb_typeof(button->'label') = 'string' AND button->>'label' ~ '[^[:space:]]' THEN
            item := item || jsonb_build_object('label',pg_temp.ticket_prefix(button->>'label',80));
          END IF;
          IF jsonb_typeof(button->'emoji') = 'object' THEN
            SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) INTO emoji
            FROM jsonb_each(button->'emoji') WHERE key IN ('id','name','animated') AND value <> 'null'::jsonb;
            IF emoji <> '{}'::jsonb THEN item := item || jsonb_build_object('emoji',emoji); END IF;
          END IF;
          IF NOT (item ? 'label' OR item ? 'emoji') THEN
            RAISE NOTICE 'Omitted unlabeled ticket welcome link for server %',guild;
            CONTINUE;
          END IF;
          IF jsonb_typeof(button->'disabled') = 'boolean' THEN item := item || jsonb_build_object('disabled',button->'disabled'); END IF;
          buttons := buttons || jsonb_build_array(item);
        END LOOP;
        IF jsonb_array_length(buttons) > 0 THEN components := components || jsonb_build_array(jsonb_build_object('type',1,'components',buttons)); END IF;
      END LOOP;
    END IF;
  END LOOP;
  IF jsonb_array_length(embeds) > 10 OR text_units > 6000 OR jsonb_array_length(components) > 5
    OR EXISTS (SELECT 1 FROM jsonb_array_elements(components) r WHERE jsonb_array_length(r->'components') > 5) THEN
    RAISE EXCEPTION 'Ticket welcome exceeds single-message Discord limits for server %',guild;
  END IF;
  IF content IS NOT NULL THEN
    IF content <> pg_temp.ticket_prefix(content,2000) THEN RAISE NOTICE 'Trimmed long ticket welcome content for server %',guild; END IF;
    result := result || jsonb_build_object('content',pg_temp.ticket_prefix(content,2000));
  END IF;
  IF jsonb_array_length(embeds) > 0 THEN result := result || jsonb_build_object('embeds',embeds); END IF;
  IF jsonb_array_length(components) > 0 THEN result := result || jsonb_build_object('components',components); END IF;
  IF result = '{}'::jsonb THEN RETURN NULL; END IF;
  RETURN result;
END;
$$;

CREATE FUNCTION pg_temp.current_ticket_settings(saved jsonb, guild text, resolve_welcome boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  result jsonb;
  key text;
  value jsonb;
  intro jsonb;
  template jsonb;
  question_limit integer;
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
  -- New applications occupy one modal. Do not change the separate pages,
  -- answers or receipts stored in an already accepted runtime operation.
  question_limit := CASE WHEN saved->'account_apply' = 'true'::jsonb THEN 4 ELSE 5 END;
  value := saved->'application_questions';
  IF value IS NULL OR value = 'null'::jsonb THEN
    value := saved->'questions';
    IF value IS NULL OR value = 'null'::jsonb THEN value := '[]'::jsonb;
    ELSIF jsonb_typeof(value) = 'string' THEN value := jsonb_build_array(value);
    END IF;
    IF jsonb_typeof(value) <> 'array' OR EXISTS(SELECT 1 FROM jsonb_array_elements(value) e WHERE jsonb_typeof(e) <> 'string') THEN RAISE EXCEPTION 'Invalid ticket questions for server %',guild; END IF;
    IF jsonb_array_length(value) > question_limit THEN RAISE NOTICE 'Trimmed trailing ticket questions for server %',guild; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(value) e WHERE e #>> '{}' <> pg_temp.ticket_label(e #>> '{}')) THEN
      RAISE NOTICE 'Normalized ticket question labels for server %',guild;
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id','migrated-' || (ordinality - 1)::text, 'label',pg_temp.ticket_label(entry #>> '{}'),
      'order',ordinality - 1, 'type','text', 'required',true, 'options','[]'::jsonb
    ) ORDER BY ordinality), '[]'::jsonb) INTO value
    FROM (SELECT entry,ordinality FROM jsonb_array_elements(value) WITH ORDINALITY q(entry,ordinality)
      WHERE entry #>> '{}' ~ '[^[:space:]]' ORDER BY ordinality LIMIT question_limit) selected;
  ELSE
    IF jsonb_typeof(value) <> 'array' OR EXISTS(SELECT 1 FROM jsonb_array_elements(value) e
      WHERE jsonb_typeof(e) <> 'object' OR jsonb_typeof(e->'label') <> 'string') THEN RAISE EXCEPTION 'Invalid ticket questions for server %',guild; END IF;
    IF jsonb_array_length(value) > question_limit THEN RAISE NOTICE 'Trimmed trailing ticket questions for server %',guild; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(value) e WHERE e->>'label' <> pg_temp.ticket_label(e->>'label')) THEN
      RAISE NOTICE 'Normalized ticket question labels for server %',guild;
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',entry->'id','label',pg_temp.ticket_label(entry->>'label'),'type',entry->'type',
      'required',entry->'required','options',entry->'options','order',entry->'order'
    ) ORDER BY ordinality), '[]'::jsonb) INTO value
    FROM (SELECT entry,ordinality FROM jsonb_array_elements(value) WITH ORDINALITY q(entry,ordinality)
      WHERE entry->>'label' ~ '[^[:space:]]' ORDER BY ordinality LIMIT question_limit) selected;
  END IF;
  result := result || jsonb_build_object('application_questions',value);
  intro := saved->'opening_message';
  IF resolve_welcome AND (intro IS NULL OR intro = 'null'::jsonb) THEN
    intro := NULL;
    IF NULLIF(saved->>'new_message','') IS NOT NULL AND saved->>'new_message' <> 'disabled' THEN
      SELECT data INTO template FROM server_custom_embeds
      WHERE server_id=guild AND name=saved->>'new_message';
      intro := pg_temp.ticket_welcome(template,guild);
      IF intro IS NULL THEN RAISE NOTICE 'Ticket welcome template unavailable or empty for server %',guild; END IF;
    END IF;
    IF intro IS NULL AND jsonb_typeof(saved->'message') = 'object' THEN
      intro := pg_temp.ticket_welcome(jsonb_build_object('embeds',jsonb_build_array(saved->'message')),guild);
    END IF;
  END IF;
  IF intro IS NOT NULL AND intro <> 'null'::jsonb THEN result := result || jsonb_build_object('opening_message',intro); END IF;
  RETURN result;
END;
$$;
-- +goose StatementEnd

-- Settings are paused before migration, but saved templates have their own
-- editor. Freeze template writes before reading them so the migration sees a
-- stable, committed source; the lock ends with this Goose transaction.
LOCK TABLE server_custom_embeds IN SHARE MODE;

-- Archived panels can still authorize staff actions for existing tickets, so
-- their saved settings need the same contract as live panels. Bypass only the
-- named archive/identity guard while this settings-only update holds the table
-- DDL lock; reenable it in this transaction before any writer can continue.
ALTER TABLE ticket_panels DISABLE TRIGGER guard_canonical_ticket_panel;
UPDATE ticket_panels p
SET data = p.data || COALESCE((
  SELECT jsonb_object_agg(e.key,pg_temp.current_ticket_settings(e.value,p.server_id))
  FROM jsonb_each(p.data) e WHERE e.key LIKE '%\_settings' ESCAPE '\'
),'{}'::jsonb);
ALTER TABLE ticket_panels ENABLE TRIGGER guard_canonical_ticket_panel;

-- An open form's context is immutable in normal operation. Temporarily disable
-- only that named guard while the migration holds the table's DDL lock, then
-- restore it in the same Goose transaction. A failure rolls back both changes.
-- Keep pages, answers, receipts and welcome snapshots unchanged. Finished and
-- already-submitted operations retain their original historical contexts.
ALTER TABLE ticket_runtime_operations DISABLE TRIGGER guard_ticket_runtime_operation;
UPDATE ticket_runtime_operations op
SET context=jsonb_set(op.context,'{settings}',pg_temp.current_ticket_settings(op.context->'settings',op.server_id,false))
WHERE op.action = 'open' AND op.state = 'preparing' AND jsonb_typeof(op.context->'settings')='object';
ALTER TABLE ticket_runtime_operations ENABLE TRIGGER guard_ticket_runtime_operation;

-- +goose Down
-- Obsolete fields are intentionally not recreated. Restore a reviewed backup
-- before rolling back to a runtime that requires the obsolete settings shape.
SELECT 1;
