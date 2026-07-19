-- ============================================================================
-- FANTAGOL
-- Migration 062: Runtime Workflow Orchestration Engine
--
-- Estende il Live Runtime esistente senza introdurre una seconda job queue.
-- live_runtime_jobs rimane l'unico execution bus.
--
-- Responsabilita:
--   * identita e stato dei workflow multi-step
--   * step DAG con dipendenze esplicite
--   * enqueue idempotente degli step pronti nella queue esistente
--   * sincronizzazione automatica job -> workflow step
--   * roll-up deterministico dello stato workflow
--   * audit append-only degli eventi di orchestrazione
--   * query layer per monitoring e Control Room
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Workflow execution aggregate
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_workflows (
  id uuid primary key default gen_random_uuid(),
  workflow_type text not null,
  workflow_version integer not null default 1,
  status text not null default 'pending',
  scope_type text not null,
  scope_id uuid not null,
  idempotency_key text not null,
  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,
  trigger_job_id uuid null references public.live_runtime_jobs(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  started_at timestamptz null,
  completed_at timestamptz null,
  failed_at timestamptz null,
  cancelled_at timestamptz null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint live_runtime_workflows_type_check
    check (nullif(btrim(workflow_type), '') is not null),
  constraint live_runtime_workflows_version_check
    check (workflow_version > 0),
  constraint live_runtime_workflows_status_check
    check (status in (
      'pending',
      'running',
      'completed',
      'failed',
      'cancelled'
    )),
  constraint live_runtime_workflows_scope_check
    check (scope_type in (
      'match',
      'fantagol_round',
      'league_round',
      'round_simulation',
      'live_state_snapshot',
      'publication'
    )),
  constraint live_runtime_workflows_identity_check
    check (nullif(btrim(idempotency_key), '') is not null),
  constraint live_runtime_workflows_terminal_check
    check (
      (status = 'completed' and completed_at is not null and failed_at is null and cancelled_at is null)
      or (status = 'failed' and failed_at is not null and completed_at is null and cancelled_at is null)
      or (status = 'cancelled' and cancelled_at is not null and completed_at is null and failed_at is null)
      or (status in ('pending', 'running') and completed_at is null and failed_at is null and cancelled_at is null)
    ),
  constraint live_runtime_workflows_dates_check
    check (
      updated_at >= created_at
      and (started_at is null or started_at >= created_at)
      and (completed_at is null or completed_at >= created_at)
      and (failed_at is null or failed_at >= created_at)
      and (cancelled_at is null or cancelled_at >= created_at)
    ),
  constraint live_runtime_workflows_idempotency_unique
    unique (idempotency_key)
);

create index if not exists live_runtime_workflows_scope_idx
  on public.live_runtime_workflows (scope_type, scope_id, created_at desc);

create index if not exists live_runtime_workflows_status_idx
  on public.live_runtime_workflows (status, updated_at desc);

create index if not exists live_runtime_workflows_correlation_idx
  on public.live_runtime_workflows (correlation_id);

comment on table public.live_runtime_workflows is
  'Aggregate di orchestrazione per workflow runtime multi-step. Non sostituisce live_runtime_jobs.';

-- --------------------------------------------------------------------------
-- 2. Workflow DAG steps
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_workflow_steps (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null
    references public.live_runtime_workflows(id) on delete cascade,
  step_key text not null,
  step_order integer not null default 100,
  job_type text not null,
  scope_type text not null,
  scope_id uuid not null,
  status text not null default 'blocked',
  depends_on text[] not null default '{}'::text[],
  job_id uuid null
    references public.live_runtime_jobs(id) on delete set null,
  idempotency_key text not null,
  priority integer not null default 100,
  max_attempts integer not null default 5,
  scheduled_at timestamptz not null default clock_timestamp(),
  payload jsonb not null default '{}'::jsonb,
  result jsonb not null default '{}'::jsonb,
  last_error jsonb null,
  enqueued_at timestamptz null,
  started_at timestamptz null,
  completed_at timestamptz null,
  failed_at timestamptz null,
  skipped_at timestamptz null,
  cancelled_at timestamptz null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),

  constraint live_runtime_workflow_steps_key_check
    check (nullif(btrim(step_key), '') is not null),
  constraint live_runtime_workflow_steps_order_check
    check (step_order >= 0),
  constraint live_runtime_workflow_steps_job_type_check
    check (nullif(btrim(job_type), '') is not null),
  constraint live_runtime_workflow_steps_scope_check
    check (scope_type in (
      'match',
      'fantagol_round',
      'league_round',
      'round_simulation',
      'live_state_snapshot',
      'publication'
    )),
  constraint live_runtime_workflow_steps_status_check
    check (status in (
      'blocked',
      'ready',
      'enqueued',
      'running',
      'retry_wait',
      'completed',
      'failed',
      'dead_letter',
      'skipped',
      'cancelled'
    )),
  constraint live_runtime_workflow_steps_priority_check
    check (priority >= 0),
  constraint live_runtime_workflow_steps_attempts_check
    check (max_attempts > 0),
  constraint live_runtime_workflow_steps_identity_check
    check (nullif(btrim(idempotency_key), '') is not null),
  constraint live_runtime_workflow_steps_dependency_self_check
    check (not (step_key = any(depends_on))),
  constraint live_runtime_workflow_steps_job_link_check
    check (
      (status in ('blocked', 'ready', 'skipped', 'cancelled') and job_id is null)
      or (status in ('enqueued', 'running', 'retry_wait', 'completed', 'failed', 'dead_letter') and job_id is not null)
    ),
  constraint live_runtime_workflow_steps_terminal_check
    check (
      (status = 'completed' and completed_at is not null)
      or (status in ('failed', 'dead_letter') and failed_at is not null)
      or (status = 'skipped' and skipped_at is not null)
      or (status = 'cancelled' and cancelled_at is not null)
      or (status in ('blocked', 'ready', 'enqueued', 'running', 'retry_wait')
          and completed_at is null and failed_at is null
          and skipped_at is null and cancelled_at is null)
    ),
  constraint live_runtime_workflow_steps_dates_check
    check (
      updated_at >= created_at
      and (enqueued_at is null or enqueued_at >= created_at)
      and (started_at is null or started_at >= created_at)
      and (completed_at is null or completed_at >= created_at)
      and (failed_at is null or failed_at >= created_at)
      and (skipped_at is null or skipped_at >= created_at)
      and (cancelled_at is null or cancelled_at >= created_at)
    ),
  constraint live_runtime_workflow_steps_workflow_key_unique
    unique (workflow_id, step_key),
  constraint live_runtime_workflow_steps_idempotency_unique
    unique (idempotency_key),
  constraint live_runtime_workflow_steps_job_unique
    unique (job_id)
);

create index if not exists live_runtime_workflow_steps_ready_idx
  on public.live_runtime_workflow_steps (workflow_id, step_order, scheduled_at)
  where status in ('blocked', 'ready');

create index if not exists live_runtime_workflow_steps_status_idx
  on public.live_runtime_workflow_steps (status, scheduled_at);

create index if not exists live_runtime_workflow_steps_job_idx
  on public.live_runtime_workflow_steps (job_id)
  where job_id is not null;

comment on table public.live_runtime_workflow_steps is
  'Step DAG di un workflow runtime. Ogni step eseguibile viene collegato a un job della queue unica.';

-- --------------------------------------------------------------------------
-- 3. Append-only workflow events
-- --------------------------------------------------------------------------

create table if not exists public.live_runtime_workflow_events (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null
    references public.live_runtime_workflows(id) on delete cascade,
  workflow_step_id uuid null
    references public.live_runtime_workflow_steps(id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  correlation_id uuid not null,
  causation_id uuid null,
  occurred_at timestamptz not null default clock_timestamp(),

  constraint live_runtime_workflow_events_type_check
    check (nullif(btrim(event_type), '') is not null)
);

create index if not exists live_runtime_workflow_events_workflow_idx
  on public.live_runtime_workflow_events (workflow_id, occurred_at, id);

create index if not exists live_runtime_workflow_events_correlation_idx
  on public.live_runtime_workflow_events (correlation_id, occurred_at);

comment on table public.live_runtime_workflow_events is
  'Audit append-only degli eventi significativi prodotti dal Workflow Orchestration Engine.';

create or replace function public.guard_live_runtime_workflow_event_append_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = 'LIVE_RUNTIME_WORKFLOW_EVENT_APPEND_ONLY';
end;
$$;

drop trigger if exists live_runtime_workflow_events_append_only_guard
  on public.live_runtime_workflow_events;

create trigger live_runtime_workflow_events_append_only_guard
before update or delete on public.live_runtime_workflow_events
for each row
execute function public.guard_live_runtime_workflow_event_append_only();

-- --------------------------------------------------------------------------
-- 4. Internal workflow state roll-up
-- --------------------------------------------------------------------------

create or replace function public.refresh_live_runtime_workflow_state(
  p_workflow_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workflow public.live_runtime_workflows%rowtype;
  v_total integer;
  v_active integer;
  v_completed integer;
  v_terminal_failure integer;
  v_cancelled integer;
  v_new_status text;
  v_old_status text;
begin
  select w.*
  into v_workflow
  from public.live_runtime_workflows w
  where w.id = p_workflow_id
  for update;

  if not found then
    return;
  end if;

  if v_workflow.status = 'cancelled' then
    return;
  end if;

  select
    count(*),
    count(*) filter (where s.status in ('enqueued', 'running', 'retry_wait')),
    count(*) filter (where s.status in ('completed', 'skipped')),
    count(*) filter (where s.status in ('failed', 'dead_letter')),
    count(*) filter (where s.status = 'cancelled')
  into
    v_total,
    v_active,
    v_completed,
    v_terminal_failure,
    v_cancelled
  from public.live_runtime_workflow_steps s
  where s.workflow_id = p_workflow_id;

  v_old_status := v_workflow.status;

  if v_total = 0 then
    v_new_status := 'pending';
  elsif v_terminal_failure > 0 then
    v_new_status := 'failed';
  elsif v_completed + v_cancelled = v_total then
    if v_cancelled = v_total then
      v_new_status := 'cancelled';
    else
      v_new_status := 'completed';
    end if;
  elsif v_active > 0 or v_completed > 0 then
    v_new_status := 'running';
  else
    v_new_status := 'pending';
  end if;

  update public.live_runtime_workflows w
  set
    status = v_new_status,
    started_at = case
      when v_new_status in ('running', 'completed', 'failed')
        then coalesce(w.started_at, clock_timestamp())
      else w.started_at
    end,
    completed_at = case
      when v_new_status = 'completed'
        then coalesce(w.completed_at, clock_timestamp())
      else null
    end,
    failed_at = case
      when v_new_status = 'failed'
        then coalesce(w.failed_at, clock_timestamp())
      else null
    end,
    cancelled_at = case
      when v_new_status = 'cancelled'
        then coalesce(w.cancelled_at, clock_timestamp())
      else null
    end,
    updated_at = clock_timestamp()
  where w.id = p_workflow_id;

  if v_new_status is distinct from v_old_status then
    insert into public.live_runtime_workflow_events (
      workflow_id,
      workflow_step_id,
      event_type,
      payload,
      correlation_id,
      causation_id
    )
    values (
      p_workflow_id,
      null,
      'RuntimeWorkflowStatusChanged',
      jsonb_build_object(
        'previous_status', v_old_status,
        'status', v_new_status,
        'total_step_count', v_total,
        'completed_step_count', v_completed,
        'active_step_count', v_active,
        'failed_step_count', v_terminal_failure,
        'cancelled_step_count', v_cancelled
      ),
      v_workflow.correlation_id,
      v_workflow.causation_id
    );
  end if;
end;
$$;

comment on function public.refresh_live_runtime_workflow_state(uuid) is
  'Ricalcola deterministicamente lo stato aggregate del workflow dai suoi step.';

-- --------------------------------------------------------------------------
-- 5. Create workflow command
--
-- p_steps JSON array contract:
-- [
--   {
--     "step_key": "rebuild",
--     "step_order": 10,
--     "job_type": "rebuild_league_round",
--     "scope_type": "league_round",       -- optional, inherits workflow
--     "scope_id": "uuid",                 -- optional, inherits workflow
--     "depends_on": [],
--     "priority": 40,
--     "max_attempts": 5,
--     "scheduled_at": "ISO timestamptz",  -- optional
--     "payload": {}
--   }
-- ]
-- --------------------------------------------------------------------------

create or replace function public.create_live_runtime_workflow_rpc(
  p_workflow_type text,
  p_scope_type text,
  p_scope_id uuid,
  p_idempotency_key text,
  p_steps jsonb,
  p_workflow_version integer default 1,
  p_metadata jsonb default '{}'::jsonb,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_trigger_job_id uuid default null
)
returns table (
  workflow_id uuid,
  workflow_status text,
  inserted boolean,
  step_count integer,
  correlation_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workflow public.live_runtime_workflows%rowtype;
  v_step jsonb;
  v_step_key text;
  v_step_scope_type text;
  v_step_scope_id uuid;
  v_depends_on text[];
  v_step_count integer := 0;
  v_missing_dependency text;
begin
  if nullif(btrim(p_workflow_type), '') is null then
    raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_TYPE_REQUIRED';
  end if;

  if p_scope_type not in (
    'match', 'fantagol_round', 'league_round',
    'round_simulation', 'live_state_snapshot', 'publication'
  ) then
    raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_SCOPE_INVALID';
  end if;

  if p_scope_id is null then
    raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_SCOPE_ID_REQUIRED';
  end if;

  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  if p_workflow_version is null or p_workflow_version <= 0 then
    raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_VERSION_INVALID';
  end if;

  if p_steps is null or jsonb_typeof(p_steps) <> 'array' or jsonb_array_length(p_steps) = 0 then
    raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_STEPS_REQUIRED';
  end if;

  insert into public.live_runtime_workflows (
    workflow_type,
    workflow_version,
    status,
    scope_type,
    scope_id,
    idempotency_key,
    correlation_id,
    causation_id,
    trigger_job_id,
    metadata
  )
  values (
    btrim(p_workflow_type),
    p_workflow_version,
    'pending',
    p_scope_type,
    p_scope_id,
    btrim(p_idempotency_key),
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    p_trigger_job_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (idempotency_key) do nothing
  returning * into v_workflow;

  if not found then
    select w.*
    into v_workflow
    from public.live_runtime_workflows w
    where w.idempotency_key = btrim(p_idempotency_key);

    select count(*)
    into v_step_count
    from public.live_runtime_workflow_steps s
    where s.workflow_id = v_workflow.id;

    return query
    select v_workflow.id, v_workflow.status, false, v_step_count, v_workflow.correlation_id;
    return;
  end if;

  for v_step in
    select value from jsonb_array_elements(p_steps)
  loop
    if jsonb_typeof(v_step) <> 'object' then
      raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_STEP_OBJECT_REQUIRED';
    end if;

    v_step_key := nullif(btrim(v_step ->> 'step_key'), '');
    if v_step_key is null then
      raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_STEP_KEY_REQUIRED';
    end if;

    if nullif(btrim(v_step ->> 'job_type'), '') is null then
      raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_STEP_JOB_TYPE_REQUIRED';
    end if;

    v_step_scope_type := coalesce(nullif(btrim(v_step ->> 'scope_type'), ''), p_scope_type);
    v_step_scope_id := coalesce(nullif(v_step ->> 'scope_id', '')::uuid, p_scope_id);

    select coalesce(array_agg(value order by ordinality), '{}'::text[])
    into v_depends_on
    from jsonb_array_elements_text(coalesce(v_step -> 'depends_on', '[]'::jsonb))
      with ordinality as dependency(value, ordinality);

    insert into public.live_runtime_workflow_steps (
      workflow_id,
      step_key,
      step_order,
      job_type,
      scope_type,
      scope_id,
      status,
      depends_on,
      idempotency_key,
      priority,
      max_attempts,
      scheduled_at,
      payload
    )
    values (
      v_workflow.id,
      v_step_key,
      coalesce((v_step ->> 'step_order')::integer, 100),
      btrim(v_step ->> 'job_type'),
      v_step_scope_type,
      v_step_scope_id,
      case when cardinality(v_depends_on) = 0 then 'ready' else 'blocked' end,
      v_depends_on,
      'workflow:' || v_workflow.id::text || ':step:' || v_step_key,
      coalesce((v_step ->> 'priority')::integer, 100),
      coalesce((v_step ->> 'max_attempts')::integer, 5),
      coalesce((v_step ->> 'scheduled_at')::timestamptz, clock_timestamp()),
      coalesce(v_step -> 'payload', '{}'::jsonb)
        || jsonb_build_object(
          'workflow_id', v_workflow.id,
          'workflow_type', v_workflow.workflow_type,
          'workflow_step_key', v_step_key
        )
    );

    v_step_count := v_step_count + 1;
  end loop;

  select dependency_name
  into v_missing_dependency
  from (
    select distinct unnest(s.depends_on) as dependency_name
    from public.live_runtime_workflow_steps s
    where s.workflow_id = v_workflow.id
  ) dependencies
  where not exists (
    select 1
    from public.live_runtime_workflow_steps defined_step
    where defined_step.workflow_id = v_workflow.id
      and defined_step.step_key = dependencies.dependency_name
  )
  limit 1;

  if v_missing_dependency is not null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKFLOW_DEPENDENCY_NOT_FOUND',
      detail = v_missing_dependency;
  end if;

  insert into public.live_runtime_workflow_events (
    workflow_id,
    workflow_step_id,
    event_type,
    payload,
    correlation_id,
    causation_id
  )
  values (
    v_workflow.id,
    null,
    'RuntimeWorkflowCreated',
    jsonb_build_object(
      'workflow_type', v_workflow.workflow_type,
      'workflow_version', v_workflow.workflow_version,
      'scope_type', v_workflow.scope_type,
      'scope_id', v_workflow.scope_id,
      'step_count', v_step_count
    ),
    v_workflow.correlation_id,
    v_workflow.causation_id
  );

  return query
  select v_workflow.id, v_workflow.status, true, v_step_count, v_workflow.correlation_id;
end;
$$;

comment on function public.create_live_runtime_workflow_rpc(
  text, text, uuid, text, jsonb, integer, jsonb, uuid, uuid, uuid
) is
  'Crea idempotentemente un workflow e il relativo DAG di step, senza ancora eseguire job.';

-- --------------------------------------------------------------------------
-- 6. Enqueue all currently-ready workflow steps
-- --------------------------------------------------------------------------

create or replace function public.enqueue_ready_live_runtime_workflow_steps_rpc(
  p_workflow_id uuid,
  p_limit integer default 25
)
returns table (
  workflow_step_id uuid,
  step_key text,
  job_id uuid,
  job_status text,
  inserted boolean,
  scheduled_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workflow public.live_runtime_workflows%rowtype;
  v_step public.live_runtime_workflow_steps%rowtype;
  v_enqueued record;
  v_limit integer;
begin
  v_limit := least(greatest(coalesce(p_limit, 25), 1), 100);

  select w.*
  into v_workflow
  from public.live_runtime_workflows w
  where w.id = p_workflow_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_NOT_FOUND';
  end if;

  if v_workflow.status in ('completed', 'failed', 'cancelled') then
    return;
  end if;

  -- Unlock blocked steps whose dependencies have all succeeded or been skipped.
  update public.live_runtime_workflow_steps candidate
  set
    status = 'ready',
    updated_at = clock_timestamp()
  where candidate.workflow_id = p_workflow_id
    and candidate.status = 'blocked'
    and not exists (
      select 1
      from unnest(candidate.depends_on) dependency(step_key)
      left join public.live_runtime_workflow_steps dependency_step
        on dependency_step.workflow_id = candidate.workflow_id
       and dependency_step.step_key = dependency.step_key
      where dependency_step.id is null
         or dependency_step.status not in ('completed', 'skipped')
    );

  for v_step in
    select s.*
    from public.live_runtime_workflow_steps s
    where s.workflow_id = p_workflow_id
      and s.status = 'ready'
      and s.scheduled_at <= clock_timestamp()
    order by s.step_order, s.created_at, s.id
    for update skip locked
    limit v_limit
  loop
    select *
    into v_enqueued
    from public.enqueue_live_runtime_job_rpc(
      p_job_type => v_step.job_type,
      p_scope_type => v_step.scope_type,
      p_scope_id => v_step.scope_id,
      p_idempotency_key => v_step.idempotency_key,
      p_priority => v_step.priority,
      p_scheduled_at => v_step.scheduled_at,
      p_payload => v_step.payload,
      p_max_attempts => v_step.max_attempts,
      p_correlation_id => v_workflow.correlation_id,
      p_causation_id => coalesce(v_workflow.trigger_job_id, v_workflow.causation_id)
    );

    update public.live_runtime_workflow_steps s
    set
      job_id = v_enqueued.job_id,
      status = case
        when v_enqueued.job_status = 'running' then 'running'
        when v_enqueued.job_status = 'retry_wait' then 'retry_wait'
        when v_enqueued.job_status = 'completed' then 'completed'
        when v_enqueued.job_status = 'dead_letter' then 'dead_letter'
        when v_enqueued.job_status = 'failed' then 'failed'
        else 'enqueued'
      end,
      enqueued_at = coalesce(s.enqueued_at, clock_timestamp()),
      started_at = case
        when v_enqueued.job_status = 'running' then coalesce(s.started_at, clock_timestamp())
        else s.started_at
      end,
      completed_at = case
        when v_enqueued.job_status = 'completed' then coalesce(s.completed_at, clock_timestamp())
        else s.completed_at
      end,
      failed_at = case
        when v_enqueued.job_status in ('failed', 'dead_letter') then coalesce(s.failed_at, clock_timestamp())
        else s.failed_at
      end,
      updated_at = clock_timestamp()
    where s.id = v_step.id;

    insert into public.live_runtime_workflow_events (
      workflow_id,
      workflow_step_id,
      event_type,
      payload,
      correlation_id,
      causation_id
    )
    values (
      p_workflow_id,
      v_step.id,
      'RuntimeWorkflowStepEnqueued',
      jsonb_build_object(
        'step_key', v_step.step_key,
        'job_id', v_enqueued.job_id,
        'job_type', v_step.job_type,
        'job_status', v_enqueued.job_status,
        'inserted', v_enqueued.inserted,
        'scheduled_at', v_enqueued.scheduled_at
      ),
      v_workflow.correlation_id,
      coalesce(v_workflow.trigger_job_id, v_workflow.causation_id)
    );

    workflow_step_id := v_step.id;
    step_key := v_step.step_key;
    job_id := v_enqueued.job_id;
    job_status := v_enqueued.job_status;
    inserted := v_enqueued.inserted;
    scheduled_at := v_enqueued.scheduled_at;
    return next;
  end loop;

  perform public.refresh_live_runtime_workflow_state(p_workflow_id);
end;
$$;

comment on function public.enqueue_ready_live_runtime_workflow_steps_rpc(uuid, integer) is
  'Risoluzione DAG ed enqueue idempotente degli step pronti nella queue live_runtime_jobs esistente.';

-- --------------------------------------------------------------------------
-- 7. Automatic job -> workflow synchronization
-- --------------------------------------------------------------------------

create or replace function public.sync_live_runtime_job_to_workflow_step()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_step public.live_runtime_workflow_steps%rowtype;
  v_workflow public.live_runtime_workflows%rowtype;
  v_step_status text;
  v_event_type text;
begin
  select s.*
  into v_step
  from public.live_runtime_workflow_steps s
  where s.job_id = new.id
  for update;

  if not found then
    return new;
  end if;

  v_step_status := case new.status
    when 'pending' then 'enqueued'
    when 'claimed' then 'running'
    when 'running' then 'running'
    when 'retry_wait' then 'retry_wait'
    when 'completed' then 'completed'
    when 'failed' then 'failed'
    when 'dead_letter' then 'dead_letter'
    when 'cancelled' then 'cancelled'
    else v_step.status
  end;

  if v_step_status is not distinct from v_step.status
     and new.result is not distinct from old.result
     and new.last_error is not distinct from old.last_error then
    return new;
  end if;

  update public.live_runtime_workflow_steps s
  set
    status = v_step_status,
    result = coalesce(new.result, '{}'::jsonb),
    last_error = new.last_error,
    started_at = case
      when v_step_status = 'running' then coalesce(s.started_at, new.claimed_at, clock_timestamp())
      else s.started_at
    end,
    completed_at = case
      when v_step_status = 'completed' then coalesce(new.completed_at, clock_timestamp())
      else null
    end,
    failed_at = case
      when v_step_status in ('failed', 'dead_letter') then coalesce(new.failed_at, clock_timestamp())
      else null
    end,
    cancelled_at = case
      when v_step_status = 'cancelled' then coalesce(new.cancelled_at, clock_timestamp())
      else null
    end,
    updated_at = clock_timestamp()
  where s.id = v_step.id;

  select w.*
  into v_workflow
  from public.live_runtime_workflows w
  where w.id = v_step.workflow_id;

  v_event_type := case v_step_status
    when 'running' then 'RuntimeWorkflowStepStarted'
    when 'retry_wait' then 'RuntimeWorkflowStepRetryScheduled'
    when 'completed' then 'RuntimeWorkflowStepCompleted'
    when 'failed' then 'RuntimeWorkflowStepFailed'
    when 'dead_letter' then 'RuntimeWorkflowStepDeadLettered'
    when 'cancelled' then 'RuntimeWorkflowStepCancelled'
    else 'RuntimeWorkflowStepUpdated'
  end;

  insert into public.live_runtime_workflow_events (
    workflow_id,
    workflow_step_id,
    event_type,
    payload,
    correlation_id,
    causation_id
  )
  values (
    v_step.workflow_id,
    v_step.id,
    v_event_type,
    jsonb_build_object(
      'step_key', v_step.step_key,
      'job_id', new.id,
      'job_type', new.job_type,
      'previous_job_status', old.status,
      'job_status', new.status,
      'workflow_step_status', v_step_status,
      'attempt_count', new.attempt_count,
      'max_attempts', new.max_attempts,
      'result', coalesce(new.result, '{}'::jsonb),
      'last_error', new.last_error
    ),
    v_workflow.correlation_id,
    new.id
  );

  perform public.refresh_live_runtime_workflow_state(v_step.workflow_id);

  return new;
end;
$$;

drop trigger if exists live_runtime_jobs_workflow_sync
  on public.live_runtime_jobs;

create trigger live_runtime_jobs_workflow_sync
after update of status, result, last_error, claimed_at, completed_at, failed_at, cancelled_at
on public.live_runtime_jobs
for each row
when (
  old.status is distinct from new.status
  or old.result is distinct from new.result
  or old.last_error is distinct from new.last_error
)
execute function public.sync_live_runtime_job_to_workflow_step();

comment on function public.sync_live_runtime_job_to_workflow_step() is
  'Sincronizza automaticamente gli stati live_runtime_jobs con lo step workflow collegato.';

-- --------------------------------------------------------------------------
-- 8. Explicit reconciliation command (recovery / maintenance)
-- --------------------------------------------------------------------------

create or replace function public.reconcile_live_runtime_workflow_rpc(
  p_workflow_id uuid
)
returns table (
  workflow_id uuid,
  workflow_status text,
  synchronized_step_count integer,
  ready_step_count integer,
  blocked_step_count integer,
  completed_step_count integer,
  failed_step_count integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer := 0;
begin
  if not exists (
    select 1 from public.live_runtime_workflows w where w.id = p_workflow_id
  ) then
    raise exception using errcode = 'P0001', message = 'LIVE_WORKFLOW_NOT_FOUND';
  end if;

  update public.live_runtime_workflow_steps s
  set
    status = case j.status
      when 'pending' then 'enqueued'
      when 'claimed' then 'running'
      when 'running' then 'running'
      when 'retry_wait' then 'retry_wait'
      when 'completed' then 'completed'
      when 'failed' then 'failed'
      when 'dead_letter' then 'dead_letter'
      when 'cancelled' then 'cancelled'
      else s.status
    end,
    result = coalesce(j.result, '{}'::jsonb),
    last_error = j.last_error,
    started_at = case
      when j.status in ('claimed', 'running') then coalesce(s.started_at, j.claimed_at, clock_timestamp())
      else s.started_at
    end,
    completed_at = case
      when j.status = 'completed' then coalesce(j.completed_at, s.completed_at, clock_timestamp())
      else null
    end,
    failed_at = case
      when j.status in ('failed', 'dead_letter') then coalesce(j.failed_at, s.failed_at, clock_timestamp())
      else null
    end,
    cancelled_at = case
      when j.status = 'cancelled' then coalesce(j.cancelled_at, s.cancelled_at, clock_timestamp())
      else null
    end,
    updated_at = clock_timestamp()
  from public.live_runtime_jobs j
  where s.workflow_id = p_workflow_id
    and s.job_id = j.id
    and (
      s.status is distinct from case j.status
        when 'pending' then 'enqueued'
        when 'claimed' then 'running'
        when 'running' then 'running'
        when 'retry_wait' then 'retry_wait'
        when 'completed' then 'completed'
        when 'failed' then 'failed'
        when 'dead_letter' then 'dead_letter'
        when 'cancelled' then 'cancelled'
        else s.status
      end
      or s.result is distinct from coalesce(j.result, '{}'::jsonb)
      or s.last_error is distinct from j.last_error
    );

  get diagnostics v_count = row_count;

  update public.live_runtime_workflow_steps candidate
  set status = 'ready', updated_at = clock_timestamp()
  where candidate.workflow_id = p_workflow_id
    and candidate.status = 'blocked'
    and not exists (
      select 1
      from unnest(candidate.depends_on) dependency(step_key)
      left join public.live_runtime_workflow_steps dependency_step
        on dependency_step.workflow_id = candidate.workflow_id
       and dependency_step.step_key = dependency.step_key
      where dependency_step.id is null
         or dependency_step.status not in ('completed', 'skipped')
    );

  perform public.refresh_live_runtime_workflow_state(p_workflow_id);

  return query
  select
    w.id,
    w.status,
    v_count,
    count(*) filter (where s.status = 'ready')::integer,
    count(*) filter (where s.status = 'blocked')::integer,
    count(*) filter (where s.status in ('completed', 'skipped'))::integer,
    count(*) filter (where s.status in ('failed', 'dead_letter'))::integer
  from public.live_runtime_workflows w
  join public.live_runtime_workflow_steps s on s.workflow_id = w.id
  where w.id = p_workflow_id
  group by w.id, w.status;
end;
$$;

comment on function public.reconcile_live_runtime_workflow_rpc(uuid) is
  'Recovery command: riallinea step e job, risolve dipendenze e ricalcola lo stato workflow.';

-- --------------------------------------------------------------------------
-- 9. Workflow status query
-- --------------------------------------------------------------------------

create or replace function public.get_live_runtime_workflow_status_rpc(
  p_workflow_id uuid
)
returns table (
  workflow_id uuid,
  workflow_type text,
  workflow_version integer,
  workflow_status text,
  scope_type text,
  scope_id uuid,
  correlation_id uuid,
  created_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  failed_at timestamptz,
  metadata jsonb,
  steps jsonb,
  recent_events jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workflow public.live_runtime_workflows%rowtype;
  v_allowed boolean := false;
begin
  select w.*
  into v_workflow
  from public.live_runtime_workflows w
  where w.id = p_workflow_id;

  if not found then
    return;
  end if;

  if auth.uid() is not null then
    if v_workflow.scope_type <> 'league_round' then
      raise exception using errcode = '42501', message = 'LIVE_WORKFLOW_ACCESS_DENIED';
    end if;

    select exists (
      select 1
      from public.league_rounds lr
      join public.league_members lm on lm.league_id = lr.league_id
      where lr.id = v_workflow.scope_id
        and lm.user_id = auth.uid()
        and lm.status = 'active'
    ) into v_allowed;

    if not v_allowed then
      raise exception using errcode = '42501', message = 'LIVE_WORKFLOW_ACCESS_DENIED';
    end if;
  end if;

  return query
  select
    v_workflow.id,
    v_workflow.workflow_type,
    v_workflow.workflow_version,
    v_workflow.status,
    v_workflow.scope_type,
    v_workflow.scope_id,
    v_workflow.correlation_id,
    v_workflow.created_at,
    v_workflow.started_at,
    v_workflow.completed_at,
    v_workflow.failed_at,
    v_workflow.metadata,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'workflow_step_id', s.id,
          'step_key', s.step_key,
          'step_order', s.step_order,
          'job_type', s.job_type,
          'scope_type', s.scope_type,
          'scope_id', s.scope_id,
          'status', s.status,
          'depends_on', to_jsonb(s.depends_on),
          'job_id', s.job_id,
          'priority', s.priority,
          'max_attempts', s.max_attempts,
          'scheduled_at', s.scheduled_at,
          'enqueued_at', s.enqueued_at,
          'started_at', s.started_at,
          'completed_at', s.completed_at,
          'failed_at', s.failed_at,
          'result', s.result,
          'last_error', s.last_error
        )
        order by s.step_order, s.created_at, s.id
      )
      from public.live_runtime_workflow_steps s
      where s.workflow_id = v_workflow.id
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(event_row.event_payload order by event_row.occurred_at, event_row.id)
      from (
        select
          e.id,
          e.occurred_at,
          jsonb_build_object(
            'event_id', e.id,
            'workflow_step_id', e.workflow_step_id,
            'event_type', e.event_type,
            'payload', e.payload,
            'correlation_id', e.correlation_id,
            'causation_id', e.causation_id,
            'occurred_at', e.occurred_at
          ) as event_payload
        from public.live_runtime_workflow_events e
        where e.workflow_id = v_workflow.id
        order by e.occurred_at desc, e.id desc
        limit 50
      ) event_row
    ), '[]'::jsonb);
end;
$$;

comment on function public.get_live_runtime_workflow_status_rpc(uuid) is
  'Query aggregata di workflow, step DAG e ultimi eventi per monitoring e Control Room.';

-- --------------------------------------------------------------------------
-- 10. Security and RLS
-- --------------------------------------------------------------------------

alter table public.live_runtime_workflows enable row level security;
alter table public.live_runtime_workflow_steps enable row level security;
alter table public.live_runtime_workflow_events enable row level security;

revoke all on table public.live_runtime_workflows from public, anon, authenticated;
revoke all on table public.live_runtime_workflow_steps from public, anon, authenticated;
revoke all on table public.live_runtime_workflow_events from public, anon, authenticated;

grant select on table public.live_runtime_workflows to service_role;
grant select on table public.live_runtime_workflow_steps to service_role;
grant select on table public.live_runtime_workflow_events to service_role;

revoke all on function public.refresh_live_runtime_workflow_state(uuid)
  from public, anon, authenticated;
revoke all on function public.create_live_runtime_workflow_rpc(
  text, text, uuid, text, jsonb, integer, jsonb, uuid, uuid, uuid
) from public, anon, authenticated;
revoke all on function public.enqueue_ready_live_runtime_workflow_steps_rpc(uuid, integer)
  from public, anon, authenticated;
revoke all on function public.reconcile_live_runtime_workflow_rpc(uuid)
  from public, anon, authenticated;
revoke all on function public.get_live_runtime_workflow_status_rpc(uuid)
  from public, anon, authenticated;

grant execute on function public.create_live_runtime_workflow_rpc(
  text, text, uuid, text, jsonb, integer, jsonb, uuid, uuid, uuid
) to service_role;
grant execute on function public.enqueue_ready_live_runtime_workflow_steps_rpc(uuid, integer)
  to service_role;
grant execute on function public.reconcile_live_runtime_workflow_rpc(uuid)
  to service_role;
grant execute on function public.get_live_runtime_workflow_status_rpc(uuid)
  to authenticated, service_role;

commit;
