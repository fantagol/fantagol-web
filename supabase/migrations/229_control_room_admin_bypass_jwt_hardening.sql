begin;

create or replace function public.control_room_read_access_allowed()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $function$
    select
        coalesce(
            current_setting('request.jwt.claim.role', true),
            ''
        ) = 'service_role'
        or (
            session_user in ('postgres', 'supabase_admin')
            and coalesce(
                current_setting('request.jwt.claim.role', true),
                ''
            ) not in ('authenticated', 'anon')
        )
        or (
            auth.uid() is not null
            and exists (
                select 1
                from public.premium_access_sessions pas
                where pas.user_id = auth.uid()
                  and pas.resource_code = 'CONTROL_ROOM'
                  and pas.status = 'active'
                  and pas.expires_at > now()
            )
        )
$function$;

comment on function public.control_room_read_access_allowed() is
'Server-side Control Room authorization gate. Authenticated users require an active unexpired CONTROL_ROOM premium session. Database-admin session_user bypass is disabled whenever request JWT role is authenticated or anon, preventing administrative connection context from overriding client authorization semantics.';

revoke all on function public.control_room_read_access_allowed()
from public;

revoke all on function public.control_room_read_access_allowed()
from anon;

revoke all on function public.control_room_read_access_allowed()
from authenticated;

grant execute on function public.control_room_read_access_allowed()
to service_role;

commit;