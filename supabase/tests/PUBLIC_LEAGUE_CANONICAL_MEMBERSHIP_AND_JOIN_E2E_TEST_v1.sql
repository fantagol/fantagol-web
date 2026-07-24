-- ============================================================================
-- FANTAGOL
-- E2E TEST
-- CANONICAL MEMBERSHIP AND PUBLIC JOIN FOUNDATION
-- Milestone 12.6 / Migration 143
-- ============================================================================

begin;

-- 1. Required objects and exact signatures.
do $$
begin
  if to_regprocedure(
    'public.join_league_membership_internal(uuid,uuid,text,text,uuid,timestamp with time zone)'
  ) is null then
    raise exception 'PUBLIC_LEAGUE_143_INTERNAL_JOIN_ASSERTION_FAILED';
  end if;

  if to_regprocedure('public.join_public_league_rpc(uuid,text)') is null then
    raise exception 'PUBLIC_LEAGUE_143_PUBLIC_JOIN_ASSERTION_FAILED';
  end if;

  if to_regprocedure('public.join_league_rpc(text,text)') is null then
    raise exception 'PUBLIC_LEAGUE_143_LEGACY_JOIN_ASSERTION_FAILED';
  end if;
end;
$$;

-- 2. Exact return contracts.
do $$
declare
  v_internal_result text;
  v_public_result text;
  v_legacy_result text;
begin
  select pg_get_function_result(
    'public.join_league_membership_internal(uuid,uuid,text,text,uuid,timestamp with time zone)'::regprocedure
  )
  into v_internal_result;

  select pg_get_function_result(
    'public.join_public_league_rpc(uuid,text)'::regprocedure
  )
  into v_public_result;

  select pg_get_function_result(
    'public.join_league_rpc(text,text)'::regprocedure
  )
  into v_legacy_result;

  if v_internal_result <>
     'TABLE(league_id uuid, membership_id uuid, join_result text)' then
    raise exception
      'PUBLIC_LEAGUE_143_INTERNAL_RETURN_CONTRACT_ASSERTION_FAILED: %',
      v_internal_result;
  end if;

  if v_public_result <>
     'TABLE(joined_league_id uuid, membership_id uuid, join_result text)' then
    raise exception
      'PUBLIC_LEAGUE_143_PUBLIC_RETURN_CONTRACT_ASSERTION_FAILED: %',
      v_public_result;
  end if;

  if v_legacy_result <> 'TABLE(joined_league_id uuid)' then
    raise exception
      'PUBLIC_LEAGUE_143_LEGACY_RETURN_CONTRACT_ASSERTION_FAILED: %',
      v_legacy_result;
  end if;
end;
$$;

-- 3. Security definer boundary.
do $$
declare
  v_internal_security boolean;
  v_public_security boolean;
  v_legacy_security boolean;
begin
  select p.prosecdef
  into v_internal_security
  from pg_proc p
  where p.oid =
    'public.join_league_membership_internal(uuid,uuid,text,text,uuid,timestamp with time zone)'::regprocedure;

  select p.prosecdef
  into v_public_security
  from pg_proc p
  where p.oid = 'public.join_public_league_rpc(uuid,text)'::regprocedure;

  select p.prosecdef
  into v_legacy_security
  from pg_proc p
  where p.oid = 'public.join_league_rpc(text,text)'::regprocedure;

  if not v_internal_security
     or not v_public_security
     or not v_legacy_security then
    raise exception 'PUBLIC_LEAGUE_143_SECURITY_DEFINER_ASSERTION_FAILED';
  end if;
end;
$$;

-- 4. Internal function must not be client callable.
do $$
begin
  if has_function_privilege(
    'anon',
    'public.join_league_membership_internal(uuid,uuid,text,text,uuid,timestamp with time zone)',
    'execute'
  ) then
    raise exception 'PUBLIC_LEAGUE_143_ANON_INTERNAL_EXECUTE_ASSERTION_FAILED';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.join_league_membership_internal(uuid,uuid,text,text,uuid,timestamp with time zone)',
    'execute'
  ) then
    raise exception 'PUBLIC_LEAGUE_143_AUTH_INTERNAL_EXECUTE_ASSERTION_FAILED';
  end if;

  if not has_function_privilege(
    'service_role',
    'public.join_league_membership_internal(uuid,uuid,text,text,uuid,timestamp with time zone)',
    'execute'
  ) then
    raise exception 'PUBLIC_LEAGUE_143_SERVICE_INTERNAL_EXECUTE_ASSERTION_FAILED';
  end if;
end;
$$;

-- 5. Public and invite wrappers must be authenticated-only client contracts.
do $$
begin
  if has_function_privilege(
    'anon',
    'public.join_public_league_rpc(uuid,text)',
    'execute'
  ) then
    raise exception 'PUBLIC_LEAGUE_143_ANON_PUBLIC_JOIN_EXECUTE_ASSERTION_FAILED';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.join_public_league_rpc(uuid,text)',
    'execute'
  ) then
    raise exception 'PUBLIC_LEAGUE_143_AUTH_PUBLIC_JOIN_EXECUTE_ASSERTION_FAILED';
  end if;

  if has_function_privilege(
    'anon',
    'public.join_league_rpc(text,text)',
    'execute'
  ) then
    raise exception 'PUBLIC_LEAGUE_143_ANON_INVITE_JOIN_EXECUTE_ASSERTION_FAILED';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.join_league_rpc(text,text)',
    'execute'
  ) then
    raise exception 'PUBLIC_LEAGUE_143_AUTH_INVITE_JOIN_EXECUTE_ASSERTION_FAILED';
  end if;
end;
$$;

-- 6. Unauthenticated wrappers must fail with AUTH_REQUIRED.
do $$
declare
  v_message text;
begin
  begin
    perform *
    from public.join_public_league_rpc(gen_random_uuid(), 'Test member');

    raise exception 'PUBLIC_LEAGUE_143_PUBLIC_AUTH_ASSERTION_DID_NOT_FAIL';
  exception
    when others then
      get stacked diagnostics v_message = message_text;

      if v_message <> 'AUTH_REQUIRED' then
        raise exception
          'PUBLIC_LEAGUE_143_PUBLIC_AUTH_ASSERTION_FAILED: %',
          v_message;
      end if;
  end;

  begin
    perform *
    from public.join_league_rpc('FG-TEST', 'Test member');

    raise exception 'PUBLIC_LEAGUE_143_INVITE_AUTH_ASSERTION_DID_NOT_FAIL';
  exception
    when others then
      get stacked diagnostics v_message = message_text;

      if v_message <> 'AUTH_REQUIRED' then
        raise exception
          'PUBLIC_LEAGUE_143_INVITE_AUTH_ASSERTION_FAILED: %',
          v_message;
      end if;
  end;
end;
$$;

-- 7. Canonical routing and idempotency markers must remain present.
do $$
declare
  v_internal_definition text;
  v_public_definition text;
  v_legacy_definition text;
begin
  select pg_get_functiondef(
    'public.join_league_membership_internal(uuid,uuid,text,text,uuid,timestamp with time zone)'::regprocedure
  )
  into v_internal_definition;

  select pg_get_functiondef(
    'public.join_public_league_rpc(uuid,text)'::regprocedure
  )
  into v_public_definition;

  select pg_get_functiondef(
    'public.join_league_rpc(text,text)'::regprocedure
  )
  into v_legacy_definition;

  if position('already_active' in v_internal_definition) = 0
     or position('reactivated' in v_internal_definition) = 0
     or position('created' in v_internal_definition) = 0 then
    raise exception 'PUBLIC_LEAGUE_143_IDEMPOTENCY_MARKERS_ASSERTION_FAILED';
  end if;

  if position('for update' in lower(v_internal_definition)) = 0 then
    raise exception 'PUBLIC_LEAGUE_143_ROW_LOCK_ASSERTION_FAILED';
  end if;

  if position('join_league_membership_internal' in v_public_definition) = 0 then
    raise exception 'PUBLIC_LEAGUE_143_PUBLIC_CANONICAL_ROUTING_ASSERTION_FAILED';
  end if;

  if position('join_league_membership_internal' in v_legacy_definition) = 0 then
    raise exception 'PUBLIC_LEAGUE_143_INVITE_CANONICAL_ROUTING_ASSERTION_FAILED';
  end if;
end;
$$;

-- 8. Public error contract markers.
do $$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.join_public_league_rpc(uuid,text)'::regprocedure
  )
  into v_definition;

  if position('PUBLIC_LEAGUE_NOT_FOUND' in v_definition) = 0
     or position('PUBLIC_LEAGUE_NOT_PUBLIC' in v_definition) = 0
     or position('PUBLIC_LEAGUE_ROSTER_LOCKED' in v_definition) = 0
     or position('PUBLIC_LEAGUE_NOT_JOINABLE' in v_definition) = 0
     or position(
       'LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT'
       in v_definition
     ) = 0 then
    raise exception 'PUBLIC_LEAGUE_143_ERROR_CONTRACT_ASSERTION_FAILED';
  end if;
end;
$$;

select
  'PUBLIC_LEAGUE_CANONICAL_MEMBERSHIP_AND_JOIN_E2E_TEST_PASSED'
  as certification_marker;

rollback;
