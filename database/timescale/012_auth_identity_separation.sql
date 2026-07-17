-- +goose Up
UPDATE public.auth_users
SET email_hash = NULL,
    password_hash = NULL,
    data = (data - 'email_encrypted' - 'email_hash' - 'password')
        #- '{linked_accounts,email}',
    updated_at = now()
WHERE COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'discord'
  AND NOT (COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'email');

-- +goose Down
-- Discord-provided email credentials cannot be reconstructed safely.
