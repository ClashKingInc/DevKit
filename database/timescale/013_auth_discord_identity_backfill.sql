-- +goose Up
UPDATE public.auth_users
SET discord_user_id = user_id,
    data = jsonb_set(
        jsonb_set(data, '{discord_user_id}', to_jsonb(user_id), true),
        '{linked_accounts}',
        COALESCE(data -> 'linked_accounts', '{}'::jsonb)
            || jsonb_build_object(
                'discord',
                COALESCE(data #> '{linked_accounts,discord}', '{}'::jsonb)
                    || jsonb_build_object('discord_user_id', user_id)
            ),
        true
    ),
    updated_at = now()
WHERE COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'discord'
  AND discord_user_id IS NULL
  AND user_id ~ '^[0-9]{15,20}$';

-- +goose Down
-- The stable Discord identity cannot be distinguished from later repairs safely.
