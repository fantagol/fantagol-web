begin;

create or replace function public.commercial_get_or_create_wallet(
  p_user_id uuid
)
returns public.commercial_wallets
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare
  v_wallet public.commercial_wallets;
begin
  if p_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'COMMERCIAL_USER_ID_REQUIRED';
  end if;

  insert into public.commercial_wallets (user_id)
  values (p_user_id)
  on conflict (user_id)
  where user_id is not null
  do nothing;

  select *
  into strict v_wallet
  from public.commercial_wallets
  where user_id = p_user_id;

  return v_wallet;
end;
$function$;

comment on function public.commercial_get_or_create_wallet(uuid)
is
  'Returns the canonical account-scoped commercial wallet, creating it when absent. '
  'Wallet materialization is concurrency-safe against the partial unique user_id index.';

commit;
