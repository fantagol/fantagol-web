-- FANTAGOL PUSH V1-L5 - SUBSCRIPTION & DELIVERY SCHEMA FOUNDATION.
-- SQL rollback canary passed; provider delivery and notification scheduling remain disabled.
-- No cron, no provider delivery, no client permissions granted.

create table public.push_preferences (
    user_id uuid primary key references auth.users(id) on delete cascade,
    enabled boolean not null default false,
    updated_at timestamptz not null default now()
);

create table public.push_devices (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    channel text not null check (channel in ('web_push', 'android_fcm')),
    endpoint_fingerprint text not null,
    -- The server stores the encrypted transport payload/token; never expose it to clients.
    encrypted_credentials bytea not null,
    enabled boolean not null default true,
    last_registered_at timestamptz not null default now(),
    invalidated_at timestamptz,
    created_at timestamptz not null default now(),
    constraint push_devices_fingerprint_unique unique (channel, endpoint_fingerprint),
    constraint push_devices_fingerprint_sha256 check (endpoint_fingerprint ~ '^[a-f0-9]{64}$')
);

create index push_devices_user_candidates_idx
    on public.push_devices (user_id, channel, last_registered_at desc)
    where enabled and invalidated_at is null;

-- A user gets one LOGICAL delivery per round, notification kind and window.
-- window_key='ordinary' for ordinary reminders/opening; use an immutable Recovery
-- authorization/window identifier for a Recovery reminder. Never reuse between windows.
create table public.push_delivery_events (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    fantagol_round_id uuid not null,
    notification_kind text not null check (
        notification_kind in ('predictions_open', 'reminder_2h', 'reminder_10m')
    ),
    window_key text not null,
    state text not null default 'pending' check (
        state in ('pending', 'leased', 'sent', 'failed', 'cancelled', 'unknown')
    ),
    device_id uuid references public.push_devices(id) on delete set null,
    attempts integer not null default 0 check (attempts >= 0),
    lease_token uuid,
    lease_expires_at timestamptz,
    provider_message_id text,
    created_at timestamptz not null default now(),
    sent_at timestamptz,
    updated_at timestamptz not null default now(),
    constraint push_delivery_events_dedup unique
        (user_id, fantagol_round_id, notification_kind, window_key),
    constraint push_delivery_events_window_key_nonempty check (length(window_key) > 0),
    constraint push_delivery_events_lease_state check (
        (state = 'leased' and lease_token is not null and lease_expires_at is not null)
        or (state <> 'leased' and lease_token is null and lease_expires_at is null)
    )
);

create index push_delivery_events_pending_idx
    on public.push_delivery_events (created_at, id)
    where state in ('pending','failed');

-- Server-only foundation. No direct user-table read/write or RPC writes.
alter table public.push_preferences enable row level security;
alter table public.push_devices enable row level security;
alter table public.push_delivery_events enable row level security;

revoke all on table public.push_preferences from public, anon, authenticated, service_role;
revoke all on table public.push_devices from public, anon, authenticated, service_role;
revoke all on table public.push_delivery_events from public, anon, authenticated, service_role;

-- No SECURITY DEFINER registration/lease RPC in this phase. Those require a
-- dedicated authentication, ownership, lease-expiry and provider-ambiguity canary.
-- No automatic resend after an unknown provider outcome; manual reconciliation.
-- Selecting an endpoint must happen once per logical event, with Android preference.
-- Suppress reminders whenever push_manual_points_submissions contains the pair.
