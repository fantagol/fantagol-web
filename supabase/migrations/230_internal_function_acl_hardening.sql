begin;

do $$
declare
  v_signature text;
  v_targets text[] := array[
    'public.append_premium_pass_lifecycle_event_internal(uuid,uuid,uuid,text,text,text,text,text,jsonb)',
    'public.protect_commercial_provider_credential_event_internal()',
    'public.protect_commercial_provider_credential_policy_internal()',
    'public.protect_commercial_provider_credential_profile_internal()',
    'public.protect_commercial_provider_credential_receipt_internal()',
    'public.protect_commercial_provider_credential_version_internal()',
    'public.protect_commercial_provider_execution_event_internal()',
    'public.protect_commercial_provider_execution_policy_internal()',
    'public.protect_commercial_provider_execution_receipt_internal()',
    'public.protect_premium_pass_lifecycle_event_internal()',
    'public.protect_premium_pass_policy_version_internal()',
    'public.set_commercial_provider_credential_updated_at_internal()',
    'public.set_commercial_provider_execution_updated_at_internal()',
    'public.append_commercial_secret_resolution_dispatch_admission_event(text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb)',
    'public.append_commercial_secret_resolution_dispatch_admission_receipt(uuid,uuid,uuid,text,text,text,text,text,jsonb)'
  ];
begin
  foreach v_signature in array v_targets
  loop
    if to_regprocedure(v_signature) is null then
      raise exception 'ACL_HARDENING_TARGET_MISSING: %', v_signature;
    end if;

    execute format('revoke all on function %s from public', v_signature);
    execute format('revoke all on function %s from anon', v_signature);
    execute format('revoke all on function %s from authenticated', v_signature);
    execute format('grant execute on function %s to service_role', v_signature);
  end loop;
end
$$;

comment on function public.append_premium_pass_lifecycle_event_internal(
  uuid,uuid,uuid,text,text,text,text,text,jsonb
) is
'Internal Premium Pass lifecycle event writer. Service-role only; client EXECUTE revoked by migration 230.';

comment on function public.append_commercial_secret_resolution_dispatch_admission_event(
  text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb
) is
'Internal commercial secret-resolution admission event writer. Service-role only; client EXECUTE revoked by migration 230.';

comment on function public.append_commercial_secret_resolution_dispatch_admission_receipt(
  uuid,uuid,uuid,text,text,text,text,text,jsonb
) is
'Internal commercial secret-resolution admission receipt writer. Service-role only; client EXECUTE revoked by migration 230.';

do $$
declare
  v_bad integer;
begin
  with targets(signature) as (
    values
      ('append_premium_pass_lifecycle_event_internal(uuid,uuid,uuid,text,text,text,text,text,jsonb)'),
      ('protect_commercial_provider_credential_event_internal()'),
      ('protect_commercial_provider_credential_policy_internal()'),
      ('protect_commercial_provider_credential_profile_internal()'),
      ('protect_commercial_provider_credential_receipt_internal()'),
      ('protect_commercial_provider_credential_version_internal()'),
      ('protect_commercial_provider_execution_event_internal()'),
      ('protect_commercial_provider_execution_policy_internal()'),
      ('protect_commercial_provider_execution_receipt_internal()'),
      ('protect_premium_pass_lifecycle_event_internal()'),
      ('protect_premium_pass_policy_version_internal()'),
      ('set_commercial_provider_credential_updated_at_internal()'),
      ('set_commercial_provider_execution_updated_at_internal()'),
      ('append_commercial_secret_resolution_dispatch_admission_event(text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,text,uuid,uuid,jsonb)'),
      ('append_commercial_secret_resolution_dispatch_admission_receipt(uuid,uuid,uuid,text,text,text,text,text,jsonb)')
  )
  select count(*)
  into v_bad
  from targets t
  join pg_proc p on p.oid = to_regprocedure('public.' || t.signature)
  where
    has_function_privilege('public', p.oid, 'EXECUTE')
    or has_function_privilege('anon', p.oid, 'EXECUTE')
    or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    or not has_function_privilege('service_role', p.oid, 'EXECUTE');

  if v_bad <> 0 then
    raise exception 'ACL_HARDENING_ASSERTION_FAILED: % target(s)', v_bad;
  end if;

  raise notice '[PASS] all 15 target functions are client-denied and service-role executable';
end
$$;

commit;