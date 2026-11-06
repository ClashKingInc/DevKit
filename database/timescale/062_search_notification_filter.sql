-- +goose Up
-- Keep PGSync bootstrap ownership on fresh databases: only replace an installed
-- function. The ck.4 image creates the same optimized function on first bootstrap.
-- Existing function ownership/grants and all row/notification semantics survive.
-- +goose StatementBegin
DO $upgrade$
BEGIN
    IF to_regprocedure('public.table_notify()') IS NOT NULL THEN
        EXECUTE $notify$
CREATE OR REPLACE FUNCTION public.table_notify() RETURNS TRIGGER AS $$
DECLARE
  channel TEXT;
  old_row JSON;
  new_row JSON;
  notification JSON;
  xmin BIGINT;
  _indices TEXT [];
  _primary_keys TEXT [];
  _foreign_keys TEXT [];
  _columns TEXT [];
  _changed BOOLEAN;
  _column TEXT;
  _old_values JSONB;
  _new_values JSONB;

BEGIN
    -- database is also the channel name.
    channel := CURRENT_DATABASE();

    IF TG_OP = 'DELETE' THEN

        SELECT primary_keys, indices INTO _primary_keys, _indices
        FROM public._view
        WHERE table_name = TG_TABLE_NAME;

        old_row = ROW_TO_JSON(OLD);
        old_row := (
            SELECT JSONB_OBJECT_AGG(key, value)
            FROM JSON_EACH(old_row)
            WHERE key = ANY(_primary_keys)
        );
        xmin := OLD.xmin;
    ELSE
        IF TG_OP <> 'TRUNCATE' THEN

            SELECT primary_keys, foreign_keys, indices, columns
            INTO _primary_keys, _foreign_keys, _indices, _columns
            FROM public._view
            WHERE table_name = TG_TABLE_NAME;

            -- normalize null to empty array
            _columns := COALESCE(_columns, ARRAY[]::TEXT[]);

            -- Only react if any _columns actually changed
            IF TG_OP = 'UPDATE' THEN
                -- Compare only configured search columns without expanding and
                -- joining every key for each high-volume observation update.
                _old_values := TO_JSONB(OLD.*);
                _new_values := TO_JSONB(NEW.*);
                _changed := FALSE;
                FOREACH _column IN ARRAY _columns LOOP
                    IF _new_values -> _column IS DISTINCT FROM _old_values -> _column THEN
                        _changed := TRUE;
                        EXIT;
                    END IF;
                END LOOP;

                IF NOT _changed THEN
                    RETURN NEW;  -- skip notification; nothing relevant changed
                END IF;
            END IF;

            new_row = ROW_TO_JSON(NEW);
            new_row := (
                SELECT JSONB_OBJECT_AGG(key, value)
                FROM JSON_EACH(new_row)
                WHERE key = ANY(_primary_keys || _foreign_keys)
            );
            IF TG_OP = 'UPDATE' THEN
                old_row = ROW_TO_JSON(OLD);
                old_row := (
                    SELECT JSONB_OBJECT_AGG(key, value)
                    FROM JSON_EACH(old_row)
                    WHERE key = ANY(_primary_keys || _foreign_keys)
                );
            END IF;
            xmin := NEW.xmin;
        END IF;
    END IF;

    -- construct the notification as a JSON object.
    notification = JSON_BUILD_OBJECT(
        'xmin', xmin,
        'new', new_row,
        'old', old_row,
        'indices', _indices,
        'tg_op', TG_OP,
        'table', TG_TABLE_NAME,
        'schema', TG_TABLE_SCHEMA
    );

    -- Notify/Listen updates occur asynchronously,
    -- so this doesn't block the Postgres trigger procedure.
    PERFORM PG_NOTIFY(channel, notification::TEXT);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
$notify$;
    END IF;
END;
$upgrade$;
-- +goose StatementEnd

-- +goose Down
-- Restore the previous filter only where PGSync is already bootstrapped.
-- +goose StatementBegin
DO $upgrade$
BEGIN
    IF to_regprocedure('public.table_notify()') IS NOT NULL THEN
        EXECUTE $notify$
CREATE OR REPLACE FUNCTION public.table_notify() RETURNS TRIGGER AS $$
DECLARE
  channel TEXT;
  old_row JSON;
  new_row JSON;
  notification JSON;
  xmin BIGINT;
  _indices TEXT [];
  _primary_keys TEXT [];
  _foreign_keys TEXT [];
  _columns TEXT [];
  _changed BOOLEAN;

BEGIN
    -- database is also the channel name.
    channel := CURRENT_DATABASE();

    IF TG_OP = 'DELETE' THEN

        SELECT primary_keys, indices INTO _primary_keys, _indices
        FROM public._view
        WHERE table_name = TG_TABLE_NAME;

        old_row = ROW_TO_JSON(OLD);
        old_row := (
            SELECT JSONB_OBJECT_AGG(key, value)
            FROM JSON_EACH(old_row)
            WHERE key = ANY(_primary_keys)
        );
        xmin := OLD.xmin;
    ELSE
        IF TG_OP <> 'TRUNCATE' THEN

            SELECT primary_keys, foreign_keys, indices, columns
            INTO _primary_keys, _foreign_keys, _indices, _columns
            FROM public._view
            WHERE table_name = TG_TABLE_NAME;

            -- normalize null to empty array
            _columns := COALESCE(_columns, ARRAY[]::TEXT[]);

            -- Only react if any _columns actually changed
            IF TG_OP = 'UPDATE' THEN
                SELECT EXISTS (
                    SELECT 1
                    FROM JSONB_EACH(TO_JSONB(NEW.*)) n
                    JOIN JSONB_EACH(TO_JSONB(OLD.*)) o USING (key)
                    WHERE n.key = ANY(_columns)
                    AND n.value IS DISTINCT FROM o.value
                )
                INTO _changed;

                IF NOT _changed THEN
                    RETURN NEW;  -- skip notification; nothing relevant changed
                END IF;
            END IF;

            new_row = ROW_TO_JSON(NEW);
            new_row := (
                SELECT JSONB_OBJECT_AGG(key, value)
                FROM JSON_EACH(new_row)
                WHERE key = ANY(_primary_keys || _foreign_keys)
            );
            IF TG_OP = 'UPDATE' THEN
                old_row = ROW_TO_JSON(OLD);
                old_row := (
                    SELECT JSONB_OBJECT_AGG(key, value)
                    FROM JSON_EACH(old_row)
                    WHERE key = ANY(_primary_keys || _foreign_keys)
                );
            END IF;
            xmin := NEW.xmin;
        END IF;
    END IF;

    -- construct the notification as a JSON object.
    notification = JSON_BUILD_OBJECT(
        'xmin', xmin,
        'new', new_row,
        'old', old_row,
        'indices', _indices,
        'tg_op', TG_OP,
        'table', TG_TABLE_NAME,
        'schema', TG_TABLE_SCHEMA
    );

    -- Notify/Listen updates occur asynchronously,
    -- so this doesn't block the Postgres trigger procedure.
    PERFORM PG_NOTIFY(channel, notification::TEXT);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
$notify$;
    END IF;
END;
$upgrade$;
-- +goose StatementEnd
