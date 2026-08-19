-- ============================================================================
-- FANTAGOL
-- ACCOUNT_RETENTION_DURATION_V1
--
-- Policy:
--   bounded bases:
--     review_at  = opened_at + 5 years
--     expires_at = opened_at + 10 years
--
--   legal_claims:
--     review_at  = opened_at + 1 year
--     expires_at = NULL while governed as legal hold
--
--   certified_game_history:
--     no commercial automatic expiry
--
-- IMPORTANT:
--   expires_at is governance metadata only.
--   This migration performs NO physical purge.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Versioned duration authority
-- --------------------------------------------------------------------------

create or replace function public.resolve_account_retention_duration_policy_internal(
  p_retention_basis text,
  p_opened_at timestamptz
)
returns table (
  policy_code text,
  policy_version integer,
  review_at timestamptz,
  expires_at timestamptz,
  automatic_expiry boolean
)
language plpgsql
stable
set search_path = public, pg_catalog
as $function$
declare
  v_basis text := nullif(btrim(p_retention_basis), '');
begin
  if p_opened_at is null then
    raise exception using
      errcode = '22004',
      message = 'RETENTION_POLICY_OPENED_AT_REQUIRED';
  end if;

  if v_basis not in (
    'commercial_ledger_integrity',
    'payment_evidence',
    'fraud_prevention',
    'legal_claims',
    'certified_game_history',
    'compliance_audit',
    'mixed'
  ) then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_POLICY_BASIS_INVALID';
  end if;

  policy_code := 'ACCOUNT_RETENTION_DURATION_V1';
  policy_version := 1;

  if v_basis in (
    'commercial_ledger_integrity',
    'payment_evidence',
    'fraud_prevention',
    'compliance_audit',
    'mixed'
  ) then
    review_at := p_opened_at + interval '5 years';
    expires_at := p_opened_at + interval '10 years';
    automatic_expiry := true;

  elsif v_basis = 'legal_claims' then
    review_at := p_opened_at + interval '1 year';
    expires_at := null;
    automatic_expiry := false;

  else
    -- certified_game_history
    review_at := null;
    expires_at := null;
    automatic_expiry := false;
  end if;

  return next;
end;
$function$;

comment on function
  public.resolve_account_retention_duration_policy_internal(text, timestamptz)
is
  'Service-only ACCOUNT_RETENTION_DURATION_V1 authority. Calculates review and ordinary expiry horizons from the original retention subject opened_at. It performs no purge.';

revoke all on function
  public.resolve_account_retention_duration_policy_internal(text, timestamptz)
from public, anon, authenticated;

grant execute on function
  public.resolve_account_retention_duration_policy_internal(text, timestamptz)
to service_role;

-- --------------------------------------------------------------------------
-- 2. Deterministic backfill of existing retention subjects
-- --------------------------------------------------------------------------

with resolved_policy as (
  select
    s.id,
    p.policy_code,
    p.policy_version,
    p.review_at,
    p.expires_at,
    p.automatic_expiry
  from public.data_retention_subjects s
  cross join lateral
    public.resolve_account_retention_duration_policy_internal(
      s.retention_basis,
      s.opened_at
    ) p
)
update public.data_retention_subjects s
set
  review_at = p.review_at,
  expires_at = p.expires_at,
  restricted_metadata =
    s.restricted_metadata ||
    jsonb_build_object(
      'retention_duration_policy_code',
        p.policy_code,
      'retention_duration_policy_version',
        p.policy_version,
      'retention_duration_policy_basis',
        s.retention_basis,
      'retention_duration_automatic_expiry',
        p.automatic_expiry
    ),
  updated_at = clock_timestamp()
from resolved_policy p
where p.id = s.id
  and (
    s.review_at is distinct from p.review_at
    or s.expires_at is distinct from p.expires_at
    or s.restricted_metadata ->> 'retention_duration_policy_code'
         is distinct from p.policy_code
    or s.restricted_metadata ->> 'retention_duration_policy_version'
         is distinct from p.policy_version::text
    or s.restricted_metadata ->> 'retention_duration_policy_basis'
         is distinct from s.retention_basis
    or s.restricted_metadata ->> 'retention_duration_automatic_expiry'
         is distinct from p.automatic_expiry::text
  );

-- --------------------------------------------------------------------------
-- 3. Future resolver: identity bridge + duration authority
-- --------------------------------------------------------------------------

create or replace function public.resolve_data_retention_subject_internal(
  p_user_id uuid,
  p_retention_basis text default 'mixed'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $function$
declare
  v_user_id uuid := p_user_id;
  v_basis text := coalesce(nullif(btrim(p_retention_basis), ''), 'mixed');
  v_subject_token text;
  v_subject_id uuid;

  v_effective_basis text;
  v_opened_at timestamptz;

  v_policy_code text;
  v_policy_version integer;
  v_review_at timestamptz;
  v_expires_at timestamptz;
  v_automatic_expiry boolean;
begin
  if v_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'RETENTION_SUBJECT_USER_ID_REQUIRED';
  end if;

  if v_basis not in (
    'commercial_ledger_integrity',
    'payment_evidence',
    'fraud_prevention',
    'legal_claims',
    'certified_game_history',
    'compliance_audit',
    'mixed'
  ) then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_SUBJECT_BASIS_INVALID';
  end if;

  -- Permanent pseudonymous identity. Raw Auth UUID is not retained
  -- by data_retention_subjects or restricted_metadata.
  v_subject_token := encode(
    extensions.digest(
      convert_to(
        'fantagol-retention-subject-v1:' || v_user_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.data_retention_subjects (
    subject_token,
    subject_class,
    retention_status,
    retention_basis,
    basis_version,
    restricted_metadata
  )
  values (
    v_subject_token,
    'account',
    'active',
    v_basis,
    1,
    jsonb_build_object(
      'identity_contract',
        'retention-subject-v1.0.1',
      'created_by',
        'identity_bridge'
    )
  )
  on conflict (subject_token)
  do update
  set
    retention_status =
      case
        when public.data_retention_subjects.retention_status = 'pending'
          then 'active'
        else public.data_retention_subjects.retention_status
      end,

    retention_basis =
      case
        when public.data_retention_subjects.retention_basis = v_basis
          then public.data_retention_subjects.retention_basis
        else 'mixed'
      end,

    version =
      public.data_retention_subjects.version + 1,

    updated_at =
      clock_timestamp()

  returning id
  into v_subject_id;

  -- Resolve against the ACTUAL persisted basis. An identity used by
  -- multiple commercial domains converges to "mixed".
  select
    s.retention_basis,
    s.opened_at
  into
    v_effective_basis,
    v_opened_at
  from public.data_retention_subjects s
  where s.id = v_subject_id;

  select
    p.policy_code,
    p.policy_version,
    p.review_at,
    p.expires_at,
    p.automatic_expiry
  into
    v_policy_code,
    v_policy_version,
    v_review_at,
    v_expires_at,
    v_automatic_expiry
  from public.resolve_account_retention_duration_policy_internal(
    v_effective_basis,
    v_opened_at
  ) p;

  update public.data_retention_subjects s
  set
    review_at = v_review_at,
    expires_at = v_expires_at,
    restricted_metadata =
      s.restricted_metadata ||
      jsonb_build_object(
        'retention_duration_policy_code',
          v_policy_code,
        'retention_duration_policy_version',
          v_policy_version,
        'retention_duration_policy_basis',
          v_effective_basis,
        'retention_duration_automatic_expiry',
          v_automatic_expiry
      ),
    updated_at = clock_timestamp()
  where s.id = v_subject_id
    and (
      s.review_at is distinct from v_review_at
      or s.expires_at is distinct from v_expires_at
      or s.restricted_metadata ->> 'retention_duration_policy_code'
           is distinct from v_policy_code
      or s.restricted_metadata ->> 'retention_duration_policy_version'
           is distinct from v_policy_version::text
      or s.restricted_metadata ->> 'retention_duration_policy_basis'
           is distinct from v_effective_basis
      or s.restricted_metadata ->> 'retention_duration_automatic_expiry'
           is distinct from v_automatic_expiry::text
    );

  update public.account_lifecycle l
  set
    retention_subject_id = v_subject_id,
    version = l.version + 1,
    updated_at = clock_timestamp()
  where l.auth_user_id = v_user_id
    and l.retention_subject_id is null;

  return v_subject_id;
end;
$function$;

comment on function
  public.resolve_data_retention_subject_internal(uuid, text)
is
  'Service-only deterministic pseudonymous retention identity resolver with ACCOUNT_RETENTION_DURATION_V1 enforcement. Raw Auth identifier is not stored in the retention subject.';

revoke all on function
  public.resolve_data_retention_subject_internal(uuid, text)
from public, anon, authenticated;

grant execute on function
  public.resolve_data_retention_subject_internal(uuid, text)
to service_role;

-- --------------------------------------------------------------------------
-- 4. Migration postconditions
-- --------------------------------------------------------------------------

do $$
declare
  v_bad bigint;
begin

  -- Bounded bases must exactly follow opened_at + 5 / +10 years.
  select count(*)
  into v_bad
  from public.data_retention_subjects
  where retention_basis in (
      'commercial_ledger_integrity',
      'payment_evidence',
      'fraud_prevention',
      'compliance_audit',
      'mixed'
    )
    and (
      review_at is distinct from opened_at + interval '5 years'
      or expires_at is distinct from opened_at + interval '10 years'
    );

  if v_bad <> 0 then
    raise exception
      'RETENTION_DURATION_BOUNDED_POSTCONDITION_FAILED rows=%',
      v_bad;
  end if;

  -- Legal claims receive review governance but no automatic expiry.
  select count(*)
  into v_bad
  from public.data_retention_subjects
  where retention_basis = 'legal_claims'
    and (
      review_at is distinct from opened_at + interval '1 year'
      or expires_at is not null
    );

  if v_bad <> 0 then
    raise exception
      'RETENTION_DURATION_LEGAL_CLAIMS_POSTCONDITION_FAILED rows=%',
      v_bad;
  end if;

  -- Competitive history remains governed by anonymization.
  select count(*)
  into v_bad
  from public.data_retention_subjects
  where retention_basis = 'certified_game_history'
    and (
      review_at is not null
      or expires_at is not null
    );

  if v_bad <> 0 then
    raise exception
      'RETENTION_DURATION_COMPETITIVE_HISTORY_POSTCONDITION_FAILED rows=%',
      v_bad;
  end if;

  -- Every subject must carry the versioned authority marker.
  select count(*)
  into v_bad
  from public.data_retention_subjects
  where restricted_metadata ->> 'retention_duration_policy_code'
          is distinct from 'ACCOUNT_RETENTION_DURATION_V1'
     or restricted_metadata ->> 'retention_duration_policy_version'
          is distinct from '1';

  if v_bad <> 0 then
    raise exception
      'RETENTION_DURATION_METADATA_POSTCONDITION_FAILED rows=%',
      v_bad;
  end if;

  -- Migration must never perform or imply a purge.
  select count(*)
  into v_bad
  from public.data_retention_subjects
  where purged_at is not null
     or retention_status = 'purged';

  if v_bad <> 0 then
    raise exception
      'RETENTION_DURATION_UNEXPECTED_PURGE_STATE rows=%',
      v_bad;
  end if;

  raise notice
    'ACCOUNT_RETENTION_DURATION_V1_CERTIFIED subjects=%',
    (select count(*) from public.data_retention_subjects);

end;
$$;

commit;
