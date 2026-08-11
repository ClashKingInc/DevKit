# Production environment contract

Coolify's server environment is the source of truth for container-hosted services. Application containers consume the canonical names directly; only third-party images and frontend build systems map those names to their required interface. There are no runtime aliases for retired names.

## Canonical Coolify server variables

```dotenv
TIMESCALE_HOST=
TIMESCALE_PORT=5432
TIMESCALE_DATABASE=clashking
TIMESCALE_USERNAME=clashking
TIMESCALE_PASSWORD=
TIMESCALE_SSLMODE=disable

VALKEY_HOST=
VALKEY_PORT=6379
VALKEY_PASSWORD=

CLASHKING_LANDING_ORIGIN=https://clashk.ing
CLASHKING_DASHBOARD_ORIGIN=https://dash.clashk.ing
CLASHKING_API_ORIGIN=https://v2-api.clashk.ing
CLASHKING_AI_ORIGIN=https://ai.clashk.ing
CLASHKING_PROXY_INTERNAL_ORIGIN=http://clashking-proxy:8011

DATA_ENCRYPTION_KEY=
JWT_ACCESS_SECRET=
JWT_REFRESH_SECRET=
NATIVE_TOKEN_AUDIENCE=clashking-native
WEB_TOKEN_AUDIENCE=clashking-web
API_BOT_TOKEN=
AI_USAGE_SECRET=

DISCORD_CLIENT_ID=
DISCORD_CLIENT_SECRET=
DISCORD_BOT_TOKEN=
COC_API_KEYS=

SMTP_HOST=
SMTP_PORT=587
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_FROM_ADDRESS=noreply@clashk.ing
SMTP_REPLY_TO_ADDRESS=noreply@clashk.ing
SMTP_STARTTLS=true
SMTP_SSL_TLS=false

CLOUDFLARE_ACCESS_TEAM_DOMAIN=
CLOUDFLARE_ACCESS_AUDIENCE=

BUNNY_ACCESS_KEY=
SENTRY_DSN_API=
SENTRY_DSN_MOBILE=
AI_ROSTER_MAX_PROMPT_CHARS=12000
AI_ROSTER_MEMBERSHIP_MAX_CHANGES=1000
ROSTER_REFRESH_COOLDOWN_MINUTES=15

MOBILE_PUSH_FCM_PROJECT_ID=clashking-prod
MOBILE_PUSH_FCM_SERVICE_ACCOUNT_JSON=

STATS_MONGODB=
STATIC_MONGODB=
R2_ACCOUNT_ID=
R2_ASSETS_ACCESS_KEY_ID=
R2_ASSETS_SECRET_ACCESS_KEY=
R2_ASSETS_BUCKET_NAME=
R2_ASSETS_PUBLIC_ORIGIN=
REDDIT_CLIENT_ID=
REDDIT_CLIENT_SECRET=
REDDIT_USERNAME=
REDDIT_PASSWORD=

STRIPE_RESTRICTED_KEY=
STRIPE_WEBHOOK_SECRET=
STRIPE_MONTHLY_PRICE_ID=
```

`DATA_ENCRYPTION_KEY` must be the key that encrypted any migrated mobile-device tokens. A new key is safe only when those encrypted tables are empty.

## Coolify resource mappings

The Timescale image requires PostgreSQL's own variable names, so its resource maps the canonical server values:

```dotenv
POSTGRES_DB={{server.TIMESCALE_DATABASE}}
POSTGRES_USER={{server.TIMESCALE_USERNAME}}
POSTGRES_PASSWORD={{server.TIMESCALE_PASSWORD}}
```

The API, admin panel, and every tracking container receive the relevant canonical names with `{{server.NAME}}`. The proxy receives `COC_API_KEYS={{server.COC_API_KEYS}}`. The admin image additionally maps its public build argument:

```dotenv
VITE_CLASHKING_API_ORIGIN={{server.CLASHKING_API_ORIGIN}}
```

If the dashboard image is built in Coolify instead of deployed through Cloudflare, map its public build arguments from the same server values:

```dotenv
NEXT_PUBLIC_CLASHKING_API_ORIGIN={{server.CLASHKING_API_ORIGIN}}
NEXT_PUBLIC_CLASHKING_AI_ORIGIN={{server.CLASHKING_AI_ORIGIN}}
NEXT_PUBLIC_DISCORD_CLIENT_ID={{server.DISCORD_CLIENT_ID}}
```

`HOST`, `PORT`, `LISTEN_HOST`, `LISTEN_PORT`, `NODE_ENV`, `LOCAL`, `MOCK_DB`, and each tracking `--script` selection are resource-local settings rather than server variables.

## Cloudflare boundary

Cloudflare Secrets Store owns `OPENAI_API_KEY` and the Worker copy of `AI_USAGE_SECRET`. The deployment environment contains the non-secret `CLOUDFLARE_SECRETS_STORE_ID`, which renders the production Wrangler config before deployment. The dashboard Worker has no runtime secrets.

`AI_USAGE_SECRET` intentionally crosses the platform boundary: the API reads it from Coolify and the AI Worker reads the identical value from Cloudflare Secrets Store. No other Cloudflare secret is duplicated into Coolify.

The public dashboard build uses `NEXT_PUBLIC_CLASHKING_API_ORIGIN`, `NEXT_PUBLIC_CLASHKING_AI_ORIGIN`, and `NEXT_PUBLIC_DISCORD_CLIENT_ID`; these are public build constants, not secrets.

## Billing state

Stripe may be configured while `subscription_support` remains disabled with zero rollout. When billing is enabled later, replace test credentials with a least-privilege live restricted key and the webhook signing secret for `https://v2-api.clashk.ing/v2/billing/stripe/webhook`.
