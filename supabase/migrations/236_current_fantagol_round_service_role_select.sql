begin;

grant select
on public.current_fantagol_round_view
to service_role;

do $assert$
begin
  if not has_table_privilege(
    'service_role',
    'public.current_fantagol_round_view',
    'SELECT'
  ) then
    raise exception
      'CURRENT_FANTAGOL_ROUND_SERVICE_ROLE_SELECT_NOT_GRANTED';
  end if;
end
$assert$;

commit;