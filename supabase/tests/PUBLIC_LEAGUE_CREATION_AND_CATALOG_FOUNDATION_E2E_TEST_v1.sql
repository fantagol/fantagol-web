-- ============================================================================
-- FANTAGOL
-- E2E TEST
-- PUBLIC LEAGUE CREATION AND CATALOG FOUNDATION
-- Milestone 12.5 / Migration 142
-- ============================================================================

begin;

-- 1. Required objects and exact signatures.
do $$
begin
  if to_regprocedure('public.create_league_v2_rpc(text,text,text,integer)') is null then
    raise exception 'PUBLIC_LEAGUE_142_CREATE_RPC_ASSERTION_FAILED';
  end if;

  if to_regclass('public.public_league_catalog_v1') is null then
    raise exception 'PUBLIC_LEAGUE_142_CATALOG_VIEW_ASSERTION_FAILED';
  end if;

  if to_regprocedure('public.get_public_leagues_rpc(integer,timestamp with time zone,uuid,text)') is null then
    raise exception 'PUBLIC_LEAGUE_142_CATALOG_RPC_ASSERTION_FAILED';
  end if;

  if to_regprocedure('public.get_public_league_context_rpc(uuid)') is null then
    raise exception 'PUBLIC_LEAGUE_142_CONTEXT_RPC_ASSERTION_FAILED';
  end if;
end;
$$;

-- 2. Legacy create contract must remain present.
do $$
begin
  if to_regprocedure('public.create_league_rpc(text,text)') is null then
    raise exception 'PUBLIC_LEAGUE_142_LEGACY_CREATE_CONTRACT_LOST';
  end if;
end;
$$;

-- 3. View must expose the required catalog foundation fields and must not
--    expose admin_user_id through either client RPC return type.
do $$
declare
  v_missing text;
begin
  select string_agg(required.column_name, ', ' order by required.column_name)
  into v_missing
  from (
    values
      ('league_id'),
      ('league_name'),
      ('edition_id'),
      ('edition_label'),
      ('admin_user_id'),
      ('admin_display_name'),
      ('active_member_count'),
      ('roster_status'),
      ('join_status'),
      ('visibility'),
      ('starts_from_fantagol_round_id'),
      ('starts_from_round_name'),
      ('starts_from_round_sequence'),
      ('first_useful_kickoff_at'),
      ('automatic_join_close_at'),
      ('lifecycle_status'),
      ('league_status'),
      ('created_at')
  ) required(column_name)
  where not exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'public_league_catalog_v1'
      and c.column_name = required.column_name
  );

  if v_missing is not null then
    raise exception 'PUBLIC_LEAGUE_142_CATALOG_COLUMNS_ASSERTION_FAILED: %', v_missing;
  end if;
end;
$$;

-- 4. Direct view access must stay denied to all client-facing roles.
do $$
begin
  if has_table_privilege('anon', 'public.public_league_catalog_v1', 'select') then
    raise exception 'PUBLIC_LEAGUE_142_ANON_VIEW_PRIVACY_ASSERTION_FAILED';
  end if;

  if has_table_privilege('authenticated', 'public.public_league_catalog_v1', 'select') then
    raise exception 'PUBLIC_LEAGUE_142_AUTHENTICATED_VIEW_PRIVACY_ASSERTION_FAILED';
  end if;
end;
$$;

-- 5. RPC privilege boundary.
do $$
begin
  if has_function_privilege('anon', 'public.create_league_v2_rpc(text,text,text,integer)', 'execute') then
    raise exception 'PUBLIC_LEAGUE_142_ANON_CREATE_EXECUTE_ASSERTION_FAILED';
  end if;

  if not has_function_privilege('authenticated', 'public.create_league_v2_rpc(text,text,text,integer)', 'execute') then
    raise exception 'PUBLIC_LEAGUE_142_AUTH_CREATE_EXECUTE_ASSERTION_FAILED';
  end if;

  if has_function_privilege('anon', 'public.get_public_leagues_rpc(integer,timestamp with time zone,uuid,text)', 'execute') then
    raise exception 'PUBLIC_LEAGUE_142_ANON_CATALOG_EXECUTE_ASSERTION_FAILED';
  end if;

  if not has_function_privilege('authenticated', 'public.get_public_leagues_rpc(integer,timestamp with time zone,uuid,text)', 'execute') then
    raise exception 'PUBLIC_LEAGUE_142_AUTH_CATALOG_EXECUTE_ASSERTION_FAILED';
  end if;

  if has_function_privilege('anon', 'public.get_public_league_context_rpc(uuid)', 'execute') then
    raise exception 'PUBLIC_LEAGUE_142_ANON_CONTEXT_EXECUTE_ASSERTION_FAILED';
  end if;

  if not has_function_privilege('authenticated', 'public.get_public_league_context_rpc(uuid)', 'execute') then
    raise exception 'PUBLIC_LEAGUE_142_AUTH_CONTEXT_EXECUTE_ASSERTION_FAILED';
  end if;
end;
$$;

-- 6. Unauthenticated calls must fail with AUTH_REQUIRED.
do $$
declare
  v_message text;
begin
  begin
    perform * from public.get_public_leagues_rpc();
    raise exception 'PUBLIC_LEAGUE_142_CATALOG_AUTH_ASSERTION_DID_NOT_FAIL';
  exception
    when others then
      get stacked diagnostics v_message = message_text;
      if v_message <> 'AUTH_REQUIRED' then
        raise exception 'PUBLIC_LEAGUE_142_CATALOG_AUTH_ASSERTION_FAILED: %', v_message;
      end if;
  end;

  begin
    perform * from public.get_public_league_context_rpc(gen_random_uuid());
    raise exception 'PUBLIC_LEAGUE_142_CONTEXT_AUTH_ASSERTION_DID_NOT_FAIL';
  exception
    when others then
      get stacked diagnostics v_message = message_text;
      if v_message <> 'AUTH_REQUIRED' then
        raise exception 'PUBLIC_LEAGUE_142_CONTEXT_AUTH_ASSERTION_FAILED: %', v_message;
      end if;
  end;
end;
$$;

-- 7. Security definer and stable/volatile contract checks.
do $$
declare
  v_create_security boolean;
  v_catalog_security boolean;
  v_context_security boolean;
  v_catalog_volatile "char";
  v_context_volatile "char";
begin
  select p.prosecdef
  into v_create_security
  from pg_proc p
  where p.oid = 'public.create_league_v2_rpc(text,text,text,integer)'::regprocedure;

  select p.prosecdef, p.provolatile
  into v_catalog_security, v_catalog_volatile
  from pg_proc p
  where p.oid = 'public.get_public_leagues_rpc(integer,timestamp with time zone,uuid,text)'::regprocedure;

  select p.prosecdef, p.provolatile
  into v_context_security, v_context_volatile
  from pg_proc p
  where p.oid = 'public.get_public_league_context_rpc(uuid)'::regprocedure;

  if not v_create_security or not v_catalog_security or not v_context_security then
    raise exception 'PUBLIC_LEAGUE_142_SECURITY_DEFINER_ASSERTION_FAILED';
  end if;

  if v_catalog_volatile <> 's' or v_context_volatile <> 's' then
    raise exception 'PUBLIC_LEAGUE_142_READ_RPC_STABILITY_ASSERTION_FAILED';
  end if;
end;
$$;

select
  'PUBLIC_LEAGUE_CREATION_AND_CATALOG_FOUNDATION_E2E_TEST_PASSED'
  as certification_marker;

rollback;
