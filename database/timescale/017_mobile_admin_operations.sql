-- +goose Up
ALTER TABLE public.mobile_push_devices
    ADD COLUMN IF NOT EXISTS authorization_status text DEFAULT 'not_determined'::text NOT NULL,
    ADD COLUMN IF NOT EXISTS locale text DEFAULT ''::text NOT NULL,
    ADD COLUMN IF NOT EXISTS timezone text DEFAULT ''::text NOT NULL;

-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'mobile_push_devices_authorization_status_check'
    ) THEN
        ALTER TABLE public.mobile_push_devices
            ADD CONSTRAINT mobile_push_devices_authorization_status_check
            CHECK (authorization_status = ANY (ARRAY[
                'authorized'::text,
                'provisional'::text,
                'denied'::text,
                'not_determined'::text
            ]));
    END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS public.mobile_notification_preferences (
    user_id text NOT NULL,
    device_id text NOT NULL,
    environment text DEFAULT 'production'::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    locale text DEFAULT ''::text NOT NULL,
    timezone text DEFAULT ''::text NOT NULL,
    enabled_types text[] DEFAULT '{}'::text[] NOT NULL,
    war_attack_modes text[] DEFAULT '{}'::text[] NOT NULL,
    event_types text[] DEFAULT '{}'::text[] NOT NULL,
    reminder_timings text[] DEFAULT '{}'::text[] NOT NULL,
    account_scope text DEFAULT 'all'::text NOT NULL,
    selected_accounts text[] DEFAULT '{}'::text[] NOT NULL,
    selected_town_halls integer[] DEFAULT '{}'::integer[] NOT NULL,
    selected_clan_tags text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    PRIMARY KEY (user_id, device_id, environment),
    CONSTRAINT mobile_notification_preferences_environment_check
        CHECK (environment = ANY (ARRAY['sandbox'::text, 'production'::text])),
    CONSTRAINT mobile_notification_preferences_account_scope_check
        CHECK (account_scope = ANY (ARRAY['all'::text, 'selected'::text]))
);

CREATE TABLE IF NOT EXISTS public.mobile_notification_subscriptions (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    user_id text NOT NULL,
    device_id text NOT NULL,
    environment text DEFAULT 'production'::text NOT NULL,
    notification_type text NOT NULL,
    player_tag text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mobile_notification_subscriptions_environment_check
        CHECK (environment = ANY (ARRAY['sandbox'::text, 'production'::text]))
);

CREATE INDEX IF NOT EXISTS idx_mobile_notification_preferences_delivery
    ON public.mobile_notification_preferences (environment, enabled)
    WHERE enabled = true;

CREATE INDEX IF NOT EXISTS idx_mobile_notification_subscriptions_device
    ON public.mobile_notification_subscriptions (user_id, device_id, environment);

CREATE TABLE IF NOT EXISTS public.admin_posts (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    slug text NOT NULL UNIQUE,
    title text NOT NULL,
    summary text NOT NULL,
    hero_image_url text,
    body_blocks jsonb DEFAULT '[]'::jsonb NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    presentation_type text DEFAULT 'article'::text NOT NULL,
    story_url text,
    story_version integer DEFAULT 1 NOT NULL,
    story_history text[] DEFAULT '{}'::text[] NOT NULL,
    revision_number integer DEFAULT 1 NOT NULL,
    show_on_home boolean DEFAULT true NOT NULL,
    pinned_on_home boolean DEFAULT false NOT NULL,
    target_route text,
    platforms text[] DEFAULT '{ios,android,web}'::text[] NOT NULL,
    dismissible boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 10 NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    also_push_on_publish boolean DEFAULT false NOT NULL,
    push_title text,
    push_body text,
    published_at timestamp with time zone,
    push_sent_at timestamp with time zone,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_posts_status_check
        CHECK ((status = ANY (ARRAY['draft'::text, 'scheduled'::text, 'live'::text, 'expired'::text, 'archived'::text]))),
    CONSTRAINT admin_posts_presentation_type_check
        CHECK ((presentation_type = ANY (ARRAY['article'::text, 'story'::text]))),
    CONSTRAINT admin_posts_story_url_check
        CHECK (presentation_type <> 'story' OR (story_url IS NOT NULL AND story_url LIKE 'https://%')),
    CONSTRAINT admin_posts_pinned_requires_home_check
        CHECK (NOT pinned_on_home OR show_on_home),
    CONSTRAINT admin_posts_story_version_check CHECK (story_version >= 1)
);

ALTER TABLE public.admin_posts
    ADD COLUMN IF NOT EXISTS translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    ADD COLUMN IF NOT EXISTS revision_number integer DEFAULT 1 NOT NULL;

CREATE TABLE IF NOT EXISTS public.admin_post_revisions (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    post_id uuid NOT NULL REFERENCES public.admin_posts(id) ON DELETE CASCADE,
    revision_number integer NOT NULL,
    snapshot jsonb NOT NULL,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    UNIQUE (post_id, revision_number)
);

CREATE TABLE IF NOT EXISTS public.admin_post_delivery_attempts (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    post_id uuid NOT NULL REFERENCES public.admin_posts(id) ON DELETE CASCADE,
    attempt_number integer NOT NULL,
    trigger text NOT NULL,
    eligible_count integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    status text NOT NULL,
    error_summary text DEFAULT ''::text NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL,
    UNIQUE (post_id, attempt_number),
    CONSTRAINT admin_post_delivery_trigger_check
        CHECK (trigger = ANY (ARRAY['publish'::text, 'retry'::text, 'manual'::text])),
    CONSTRAINT admin_post_delivery_status_check
        CHECK (status = ANY (ARRAY['sent'::text, 'partial'::text, 'failed'::text, 'no_audience'::text]))
);

CREATE TABLE IF NOT EXISTS public.admin_notification_campaigns (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    campaign_key text NOT NULL UNIQUE,
    title text NOT NULL,
    body text NOT NULL,
    target_route text,
    platforms text[] DEFAULT '{ios,android,web}'::text[] NOT NULL,
    target_locales text[] DEFAULT '{}'::text[] NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    trigger_type text DEFAULT 'manual'::text NOT NULL,
    day_of_month integer,
    send_at timestamp with time zone,
    send_time text DEFAULT '09:00'::text,
    last_sent_at timestamp with time zone,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_notification_campaign_status_check CHECK (status = ANY (ARRAY['draft'::text, 'scheduled'::text, 'sent'::text, 'paused'::text])),
    CONSTRAINT admin_notification_campaign_trigger_check CHECK (trigger_type = ANY (ARRAY['manual'::text, 'monthly'::text])),
    CONSTRAINT admin_notification_campaign_day_check CHECK (day_of_month IS NULL OR day_of_month BETWEEN 1 AND 28),
    CONSTRAINT admin_notification_campaign_send_time_check CHECK (send_time IS NULL OR send_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
    CONSTRAINT admin_notification_campaign_locales_check CHECK (target_locales IS NOT NULL)
);

ALTER TABLE public.admin_notification_campaigns
    ADD COLUMN IF NOT EXISTS target_locales text[] DEFAULT '{}'::text[] NOT NULL,
    ADD COLUMN IF NOT EXISTS translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    ADD COLUMN IF NOT EXISTS send_time text DEFAULT '09:00'::text;

-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'admin_notification_campaign_send_time_check'
          AND conrelid = 'public.admin_notification_campaigns'::regclass
    ) THEN
        ALTER TABLE public.admin_notification_campaigns
            ADD CONSTRAINT admin_notification_campaign_send_time_check
            CHECK (send_time IS NULL OR send_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'admin_notification_campaign_locales_check'
          AND conrelid = 'public.admin_notification_campaigns'::regclass
    ) THEN
        ALTER TABLE public.admin_notification_campaigns
            ADD CONSTRAINT admin_notification_campaign_locales_check
            CHECK (target_locales IS NOT NULL);
    END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS public.admin_feature_flags (
    flag_key text NOT NULL PRIMARY KEY,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    rollout_percentage integer DEFAULT 0 NOT NULL,
    min_app_version text DEFAULT ''::text NOT NULL,
    platforms text[] DEFAULT '{ios,android}'::text[] NOT NULL,
    owner_name text DEFAULT 'Product'::text NOT NULL,
    public_exposure text DEFAULT 'safe'::text NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_feature_flags_rollout_check CHECK (rollout_percentage BETWEEN 0 AND 100),
    CONSTRAINT admin_feature_flags_exposure_check CHECK (public_exposure = ANY (ARRAY['safe'::text, 'sensitive'::text]))
);

CREATE TABLE IF NOT EXISTS public.admin_kpi_daily (
    snapshot_date date NOT NULL PRIMARY KEY,
    devices_total integer DEFAULT 0 NOT NULL,
    devices_production integer DEFAULT 0 NOT NULL,
    devices_sandbox integer DEFAULT 0 NOT NULL,
    devices_opted_in integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.admin_audit_events (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    actor text NOT NULL,
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id text DEFAULT ''::text NOT NULL,
    summary text DEFAULT ''::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    ip_address text DEFAULT ''::text NOT NULL,
    user_agent text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.admin_users (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    discord_user_id text NOT NULL UNIQUE,
    username text NOT NULL,
    display_name text NOT NULL,
    avatar_url text DEFAULT ''::text NOT NULL,
    role text DEFAULT 'owner'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    last_login_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_users_role_check CHECK (role = ANY (ARRAY['owner'::text, 'admin'::text]))
);

CREATE TABLE IF NOT EXISTS public.admin_sessions (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES public.admin_users(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,
    expires_at timestamp with time zone NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    ip_address text DEFAULT ''::text NOT NULL,
    user_agent text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_admin_sessions_user_active
    ON public.admin_sessions (user_id, expires_at DESC)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS public.admin_campaign_delivery_attempts (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    campaign_id uuid NOT NULL REFERENCES public.admin_notification_campaigns(id) ON DELETE CASCADE,
    scheduled_for date NOT NULL,
    eligible_count integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    status text NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL,
    UNIQUE (campaign_id, scheduled_for)
);

-- Migration 009 introduced the original announcement model. All current
-- consumers use admin_posts, so preserve legacy rows before retiring it.
-- +goose StatementBegin
DO $$
BEGIN
    IF to_regclass('public.app_announcements') IS NOT NULL THEN
        INSERT INTO public.admin_posts (
            id, slug, title, summary, hero_image_url, body_blocks,
            presentation_type, story_url, show_on_home, platforms, status,
            starts_at, ends_at, published_at, created_at, updated_at
        )
        SELECT
            id,
            'legacy-announcement-' || id::text,
            title,
            subtitle,
            banner_image_url,
            CASE
                WHEN btrim(body) = '' THEN '[]'::jsonb
                ELSE jsonb_build_array(jsonb_build_object('type', 'paragraph', 'text', body))
            END,
            CASE WHEN html_url LIKE 'https://%' THEN 'story' ELSE 'article' END,
            CASE WHEN html_url LIKE 'https://%' THEN html_url ELSE NULL END,
            true,
            CASE WHEN target = 'all' THEN ARRAY['ios', 'android', 'web']::text[] ELSE ARRAY[target]::text[] END,
            CASE
                WHEN status = 'published' AND ends_at IS NOT NULL AND ends_at <= now() THEN 'expired'
                WHEN status = 'published' THEN 'live'
                ELSE status
            END,
            starts_at,
            ends_at,
            CASE WHEN status = 'published' THEN starts_at ELSE NULL END,
            created_at,
            updated_at
        FROM public.app_announcements
        ON CONFLICT (id) DO NOTHING;

        DROP TABLE public.app_announcements;
    END IF;
END $$;
-- +goose StatementEnd

INSERT INTO public.admin_notification_campaigns
    (campaign_key, title, body, target_route, platforms, translations, status, trigger_type, day_of_month, send_time, last_sent_at, created_by)
VALUES
    (
        'monthly-support',
        'New Season is Live',
        'A new season has started. If you''re getting the Gold Pass, consider using creator code ClashKing. ❤️',
        '/settings/support',
        '{ios,android,web}',
        $translations${
          "af": {"title": "Nuwe seisoen is hier", "body": "'n Nuwe seisoen het begin. As jy die Goue Pas koop, oorweeg dit om skepparkode ClashKing te gebruik. ❤️"},
          "ar": {"title": "الموسم الجديد متاح الآن", "body": "بدأ موسم جديد. إذا كنت ستحصل على التذكرة الذهبية، ففكّر في استخدام رمز المنشئ ClashKing. ❤️"},
          "ca": {"title": "La nova temporada ja és aquí", "body": "Ha començat una nova temporada. Si compraràs el Passi d'Or, considera utilitzar el codi de creador ClashKing. ❤️"},
          "cs": {"title": "Nová sezóna je tady", "body": "Začala nová sezóna. Pokud si pořídíte Zlatý pas, zvažte použití kódu tvůrce ClashKing. ❤️"},
          "da": {"title": "Den nye sæson er i gang", "body": "En ny sæson er begyndt. Hvis du køber Guldpasset, kan du overveje at bruge skaberkoden ClashKing. ❤️"},
          "de": {"title": "Die neue Saison ist da", "body": "Eine neue Saison hat begonnen. Wenn du den Goldpass kaufst, verwende gerne den Creator-Code ClashKing. ❤️"},
          "el": {"title": "Η νέα σεζόν ξεκίνησε", "body": "Μια νέα σεζόν ξεκίνησε. Αν πρόκειται να αγοράσεις το Χρυσό Πάσο, σκέψου να χρησιμοποιήσεις τον creator code ClashKing. ❤️"},
          "es": {"title": "La nueva temporada ya está aquí", "body": "Ha comenzado una nueva temporada. Si vas a comprar el Pase de Oro, considera usar el código de creador ClashKing. ❤️"},
          "fi": {"title": "Uusi kausi on täällä", "body": "Uusi kausi on alkanut. Jos aiot hankkia Kultapassin, harkitse sisällöntuottajakoodin ClashKing käyttämistä. ❤️"},
          "fr": {"title": "La nouvelle saison est arrivée", "body": "Une nouvelle saison a commencé. Si tu achètes le Pass Or, pense à utiliser le code créateur ClashKing. ❤️"},
          "he": {"title": "העונה החדשה כאן", "body": "עונה חדשה התחילה. אם בכוונתך לרכוש את כרטיס הזהב, כדאי להשתמש בקוד היוצר ClashKing. ❤️"},
          "hi": {"title": "नया सीज़न शुरू हो गया है", "body": "एक नया सीज़न शुरू हो गया है। अगर आप गोल्ड पास खरीद रहे हैं, तो क्रिएटर कोड ClashKing इस्तेमाल करने पर विचार करें। ❤️"},
          "hu": {"title": "Itt az új szezon", "body": "Elkezdődött egy új szezon. Ha megveszed az Aranybérletet, fontold meg a ClashKing alkotói kód használatát. ❤️"},
          "it": {"title": "La nuova stagione è arrivata", "body": "È iniziata una nuova stagione. Se acquisti il Pass d'oro, considera di usare il codice creatore ClashKing. ❤️"},
          "ja": {"title": "新シーズン開幕", "body": "新しいシーズンが始まりました。ゴールドパスを購入する場合は、クリエイターコード「ClashKing」の使用をご検討ください。❤️"},
          "ko": {"title": "새 시즌이 시작되었습니다", "body": "새 시즌이 시작되었습니다. 골드 패스를 구매하신다면 크리에이터 코드 ClashKing을 사용해 주세요. ❤️"},
          "nl": {"title": "Het nieuwe seizoen is begonnen", "body": "Er is een nieuw seizoen begonnen. Koop je de Goudpas, overweeg dan de creatorcode ClashKing te gebruiken. ❤️"},
          "no": {"title": "Den nye sesongen er i gang", "body": "En ny sesong har startet. Hvis du kjøper Gullpasset, kan du vurdere å bruke skaperkoden ClashKing. ❤️"},
          "pl": {"title": "Nowy sezon już trwa", "body": "Rozpoczął się nowy sezon. Jeśli kupujesz Złotą Przepustkę, rozważ użycie kodu twórcy ClashKing. ❤️"},
          "pt": {"title": "A nova temporada chegou", "body": "Uma nova temporada começou. Se você for comprar o Passe de Ouro, considere usar o código de criador ClashKing. ❤️"},
          "ro": {"title": "Noul sezon a început", "body": "A început un sezon nou. Dacă achiziționezi Permisul de Aur, ia în considerare folosirea codului de creator ClashKing. ❤️"},
          "ru": {"title": "Новый сезон уже начался", "body": "Начался новый сезон. Если вы покупаете Золотой пропуск, рассмотрите возможность использовать код автора ClashKing. ❤️"},
          "sr": {"title": "Нова сезона је почела", "body": "Почела је нова сезона. Ако купујете Златну пропусницу, размислите о коришћењу кода креатора ClashKing. ❤️"},
          "sv": {"title": "Den nya säsongen är här", "body": "En ny säsong har börjat. Om du köper Guldpasset kan du överväga att använda skaparkoden ClashKing. ❤️"},
          "tr": {"title": "Yeni sezon başladı", "body": "Yeni bir sezon başladı. Altın Bilet satın alacaksan içerik üreticisi kodu ClashKing'i kullanmayı düşünebilirsin. ❤️"},
          "uk": {"title": "Новий сезон уже почався", "body": "Розпочався новий сезон. Якщо ви купуєте Золотий пропуск, скористайтеся кодом автора ClashKing. ❤️"},
          "ur": {"title": "نیا سیزن شروع ہو گیا ہے", "body": "نیا سیزن شروع ہو گیا ہے۔ اگر آپ گولڈ پاس خرید رہے ہیں تو کریئیٹر کوڈ ClashKing استعمال کرنے پر غور کریں۔ ❤️"},
          "vi": {"title": "Mùa giải mới đã bắt đầu", "body": "Một mùa giải mới đã bắt đầu. Nếu bạn mua Vé Vàng, hãy cân nhắc sử dụng mã nhà sáng tạo ClashKing. ❤️"},
          "zh": {"title": "新赛季已开启", "body": "新赛季已经开始。如果你准备购买黄金令牌，请考虑使用创作者代码 ClashKing。❤️"}
        }$translations$::jsonb,
        'scheduled',
        'monthly',
        1,
        '09:00',
        now(),
        'system'
    )
ON CONFLICT (campaign_key) DO NOTHING;

-- Mobile feature catalogue. Established features fail open in the client;
-- preview/incomplete surfaces are disabled until explicitly enabled by an
-- administrator. ON CONFLICT preserves values already configured pre-prod.
INSERT INTO public.admin_feature_flags
    (flag_key, name, description, enabled, rollout_percentage, platforms, owner_name, public_exposure)
VALUES
    ('notifications', 'Notification settings', 'Controls push initialization, device registration, and notification settings.', true, 100, '{ios,android}', 'Mobile', 'safe'),
    ('posts', 'Posts archive', 'Shows the posts archive in the account drawer.', true, 100, '{ios,android,web}', 'Content', 'safe'),
    ('home_announcements', 'Home announcements', 'Allows featured post stories to open automatically on the home screen.', true, 100, '{ios,android}', 'Content', 'safe'),
    ('popular_insights', 'Popular insights', 'Shows the experimental locally-derived Popular screen.', false, 0, '{ios,android,web}', 'Product', 'safe'),
    ('leaderboards', 'Leaderboards', 'Shows official player and clan leaderboards backed by the Clash API proxy.', true, 100, '{ios,android,web}', 'Product', 'safe'),
    ('leaderboard_previews', 'Leaderboard endpoint previews', 'Shows unfinished ClashKing leaderboard endpoint mockups below official rankings.', false, 0, '{ios,android,web}', 'Product', 'safe'),
    ('global_stats', 'Global stats', 'Shows aggregate ranking statistics backed by the Clash API proxy.', true, 100, '{ios,android,web}', 'Product', 'safe'),
    ('calculators', 'Calculators', 'Shows ore, ZapQuake, and Fireball calculators.', true, 100, '{ios,android,web}', 'Mobile', 'safe'),
    ('subscription_support', 'Subscription support', 'Shows the unfinished monthly support subscription surface.', false, 0, '{ios,android}', 'Product', 'safe'),
    ('upgrade_tracker', 'Upgrade tracker', 'Shows the upgrade tracker and its remote game-data integration.', true, 100, '{ios,android,web}', 'Mobile', 'safe'),
    ('bases_armies', 'Bases and armies', 'Shows the unfinished Discord-synced bases and armies surface.', false, 0, '{ios,android,web}', 'Discord', 'safe'),
    ('game_assets', 'Game assets', 'Shows the browsable Clash of Clans asset catalogue.', true, 100, '{ios,android,web}', 'Mobile', 'safe'),
    ('clan_rankings_preview', 'Clan rankings preview', 'Shows fabricated clan ranking previews while the real endpoint is unavailable.', false, 0, '{ios,android,web}', 'Product', 'safe'),
    ('cwl_history_preview', 'CWL history preview', 'Shows fabricated CWL history while the real endpoint is unavailable.', false, 0, '{ios,android,web}', 'Product', 'safe'),
    ('account_connections', 'Account connection controls', 'Shows unfinished Discord and email connect/disconnect controls in Settings.', false, 0, '{ios,android,web}', 'Auth', 'safe'),
    ('war_widgets', 'War widgets', 'Shows war home-screen widget configuration and background refresh integration.', true, 100, '{ios,android}', 'Mobile', 'safe'),
    ('feature_requests', 'Feature requests', 'Shows the embedded external feature-request portal.', true, 100, '{ios,android,web}', 'Product', 'safe')
ON CONFLICT (flag_key) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_admin_posts_status ON public.admin_posts (status);
CREATE INDEX IF NOT EXISTS idx_admin_feature_flags_active ON public.admin_feature_flags (enabled, starts_at, ends_at);
CREATE INDEX IF NOT EXISTS idx_admin_audit_events_created ON public.admin_audit_events (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_events_resource ON public.admin_audit_events (resource_type, resource_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_posts_starts_at ON public.admin_posts (starts_at) WHERE status = 'scheduled';
CREATE INDEX IF NOT EXISTS idx_admin_posts_home_selection
    ON public.admin_posts (pinned_on_home DESC, priority DESC, published_at DESC)
    WHERE status = 'live' AND show_on_home = true;
CREATE INDEX IF NOT EXISTS idx_admin_post_revisions_post
    ON public.admin_post_revisions (post_id, revision_number DESC);
CREATE INDEX IF NOT EXISTS idx_admin_post_delivery_attempts_post
    ON public.admin_post_delivery_attempts (post_id, attempt_number DESC);
CREATE INDEX IF NOT EXISTS idx_admin_notification_campaigns_due
    ON public.admin_notification_campaigns (status, trigger_type, send_at, day_of_month, send_time);
CREATE INDEX IF NOT EXISTS idx_admin_notification_campaigns_target_locales
    ON public.admin_notification_campaigns USING gin (target_locales);

-- +goose Down
DROP TABLE IF EXISTS public.admin_campaign_delivery_attempts;
DROP TABLE IF EXISTS public.admin_sessions;
DROP TABLE IF EXISTS public.admin_users;
DROP TABLE IF EXISTS public.admin_notification_campaigns;
DROP TABLE IF EXISTS public.admin_post_delivery_attempts;
DROP TABLE IF EXISTS public.admin_post_revisions;
DROP TABLE IF EXISTS public.admin_posts CASCADE;
DROP TABLE IF EXISTS public.admin_feature_flags;
DROP TABLE IF EXISTS public.admin_kpi_daily;
DROP TABLE IF EXISTS public.admin_audit_events;
DROP TABLE IF EXISTS public.mobile_notification_subscriptions;
DROP TABLE IF EXISTS public.mobile_notification_preferences;

ALTER TABLE public.mobile_push_devices
    DROP CONSTRAINT IF EXISTS mobile_push_devices_authorization_status_check,
    DROP COLUMN IF EXISTS authorization_status,
    DROP COLUMN IF EXISTS locale,
    DROP COLUMN IF EXISTS timezone;
