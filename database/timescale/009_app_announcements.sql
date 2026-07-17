-- +goose Up
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.app_announcements (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    title text NOT NULL,
    subtitle text NOT NULL,
    body text DEFAULT '' NOT NULL,
    status text DEFAULT 'draft' NOT NULL CHECK (status IN ('draft', 'scheduled', 'published', 'archived')),
    target text DEFAULT 'all' NOT NULL CHECK (target IN ('all', 'ios', 'android')),
    banner_image_url text,
    html_object_key text,
    html_url text,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone,
    min_app_version text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_app_announcements_active
    ON public.app_announcements (status, target, starts_at, ends_at);

CREATE INDEX IF NOT EXISTS idx_app_announcements_created
    ON public.app_announcements (created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS public.app_announcements CASCADE;
