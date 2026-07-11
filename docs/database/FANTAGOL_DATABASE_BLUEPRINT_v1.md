# FANTAGOL DATABASE BLUEPRINT v1

**Stato:** design freeze candidate  
**Ambito:** schema canonico finale della Foundation Database  
**Obiettivo:** descrivere in modo completo e non ambiguo tutti gli oggetti database che devono esistere al termine della Foundation Migration.

---

# 0. AUTORITÀ E SCOPO

Questo Blueprint traduce in schema concreto:

- Domain Dictionary;
- Game Engine Master;
- Core Engine Master;
- Competition Engine Master;
- Competition Database Design;
- Foundation Database Master.

La Foundation Migration deve essere una traduzione meccanica di questo documento.

Il Blueprint copre esclusivamente:

```text
Competition Core
Provider Registry
FantaGol Round Core
Legacy Bridge
RLS
Read Models
Pure Helpers
Audit Competition
```

Non copre ancora:

```text
Prediction Engine
Odds Engine
Scoring Engine
Strategy Engine
Mode Engine
Standings Engine
Live Engine
Core Event Store
Control Room
Monetisation
Notifications
```

---

# 1. LEGACY OBJECTS PRESERVED

Le seguenti tabelle esistenti restano operative:

```text
profiles
clubs
leagues
league_members
seasons
matchdays
teams
matches
predictions
```

Nella Foundation Migration:

- non vengono eliminate;
- non vengono rinominate;
- non vengono rese incompatibili;
- mantengono tutte le colonne originarie;
- `teams` e `matches` vengono estese;
- `seasons` e `matchdays` restano legacy-supported.

---

# 2. CANONICAL TABLES

## 2.1 sports

### Purpose

Registro degli sport supportati.

### Columns

```text
id uuid primary key default gen_random_uuid()
code text not null
name_key text not null
active boolean not null default true
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
version integer not null default 1
```

### Constraints

```text
unique(code)
check(trim(code) <> '')
check(trim(name_key) <> '')
check(version > 0)
```

### Indexes

```text
sports_active_idx(active)
```

### RLS

```text
anon: read active rows
authenticated: read active rows
client write: denied
service_role: full access
```

---

## 2.2 competitions

### Purpose

Registro universale delle competizioni reali.

### Columns

```text
id uuid primary key default gen_random_uuid()
sport_id uuid not null
code text not null
name_key text not null
short_name_key text null
country_code text null
confederation_code text null
competition_type text not null
scope text not null
gender text not null default 'male'
enabled boolean not null default false
public boolean not null default false
beta boolean not null default false
launch_date date null
priority integer not null default 100
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
version integer not null default 1
```

### FK

```text
sport_id → sports.id ON DELETE RESTRICT
```

### Allowed competition_type

```text
league
domestic_cup
continental_club
national_team_tournament
qualifier
super_cup
friendly_tournament
```

### Allowed scope

```text
domestic
continental
international
```

### Allowed gender

```text
male
female
mixed
```

### Constraints

```text
unique(code)
check(trim(code) <> '')
check(trim(name_key) <> '')
check(priority >= 0)
check(version > 0)
```

### Indexes

```text
competitions_sport_idx(sport_id)
competitions_enabled_public_idx(enabled, public)
competitions_priority_idx(priority)
competitions_country_idx(country_code)
```

### RLS

```text
anon: enabled = true AND public = true
authenticated: enabled = true
client write: denied
service_role: full access
```

---

## 2.3 competition_editions

### Purpose

Stagione o edizione di una Competition.

### Columns

```text
id uuid primary key default gen_random_uuid()
competition_id uuid not null
label text not null
provider_label text null
year_start integer not null
year_end integer null
starts_at timestamptz not null
ends_at timestamptz not null
status text not null default 'draft'
active boolean not null default true
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
version integer not null default 1
```

### FK

```text
competition_id → competitions.id ON DELETE RESTRICT
```

### Allowed status

```text
draft
scheduled
active
completed
archived
cancelled
```

### Constraints

```text
unique(competition_id, label)
check(trim(label) <> '')
check(year_start between 1900 and 2200)
check(year_end is null or year_end between year_start and year_start + 2)
check(starts_at < ends_at)
check(version > 0)
```

### Indexes

```text
competition_editions_competition_idx(competition_id)
competition_editions_status_idx(status)
competition_editions_active_idx(active)
competition_editions_dates_idx(starts_at, ends_at)
```

### RLS

Inherited visibility from parent Competition.

---

## 2.4 competition_stages

### Purpose

Fase interna di una Competition Edition.

### Columns

```text
id uuid primary key default gen_random_uuid()
edition_id uuid not null
code text not null
name_key text not null
stage_type text not null
sequence integer not null
starts_at timestamptz null
ends_at timestamptz null
active boolean not null default true
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
version integer not null default 1
```

### FK

```text
edition_id → competition_editions.id ON DELETE CASCADE
```

### Allowed stage_type

```text
regular_season
league_phase
group_stage
playoff
round_of_128
round_of_64
round_of_32
round_of_16
quarter_final
semi_final
third_place
final
qualifier
preliminary
relegation
promotion
```

### Constraints

```text
unique(edition_id, code)
unique(edition_id, sequence)
check(trim(code) <> '')
check(trim(name_key) <> '')
check(sequence > 0)
check(starts_at is null or ends_at is null or starts_at < ends_at)
check(version > 0)
```

### Indexes

```text
competition_stages_edition_idx(edition_id)
competition_stages_type_idx(stage_type)
competition_stages_active_idx(active)
```

### RLS

Inherited visibility from parent Competition.

---

## 2.5 competition_teams

### Purpose

Partecipazione di un Team a una Competition Edition.

### Columns

```text
id uuid primary key default gen_random_uuid()
edition_id uuid not null
team_id uuid not null
group_code text null
seed integer null
active boolean not null default true
joined_at timestamptz not null default now()
left_at timestamptz null
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
```

### FK

```text
edition_id → competition_editions.id ON DELETE CASCADE
team_id → teams.id ON DELETE RESTRICT
```

### Constraints

```text
unique(edition_id, team_id)
check(seed is null or seed > 0)
check(left_at is null or left_at >= joined_at)
```

### Indexes

```text
competition_teams_edition_idx(edition_id)
competition_teams_team_idx(team_id)
competition_teams_group_idx(edition_id, group_code)
```

### RLS

Inherited visibility from parent Competition.

---

## 2.6 data_providers

### Purpose

Registro interno dei provider.

### Columns

```text
id uuid primary key default gen_random_uuid()
code text not null
name text not null
provider_type text not null
active boolean not null default true
priority integer not null default 100
base_url text null
rate_limit_per_minute integer null
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
```

### Allowed provider_type

```text
calendar
live_score
odds
multi
```

### Constraints

```text
unique(code)
check(trim(code) <> '')
check(trim(name) <> '')
check(priority >= 0)
check(rate_limit_per_minute is null or rate_limit_per_minute > 0)
```

### Indexes

```text
data_providers_active_priority_idx(active, priority)
```

### RLS

```text
anon: denied
authenticated: denied
client write: denied
service_role: full access
```

---

## 2.7 provider_entity_maps

### Purpose

Mapping tra entità interne e identificativi provider.

### Columns

```text
id uuid primary key default gen_random_uuid()
provider_id uuid not null
entity_type text not null
internal_id uuid not null
external_id text not null
external_parent_id text null
metadata jsonb not null default '{}'::jsonb
active boolean not null default true
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
```

### FK

```text
provider_id → data_providers.id ON DELETE CASCADE
```

### Allowed entity_type

```text
competition
edition
stage
team
provider_round
match
```

### Constraints

```text
unique(provider_id, entity_type, external_id)
unique(provider_id, entity_type, internal_id)
check(trim(external_id) <> '')
```

### Indexes

```text
provider_entity_maps_internal_idx(entity_type, internal_id)
provider_entity_maps_external_idx(provider_id, entity_type, external_id)
provider_entity_maps_active_idx(active)
```

### RLS

Service role only.

---

## 2.8 provider_rounds

### Purpose

Turno così come fornito dal provider.

### Columns

```text
id uuid primary key default gen_random_uuid()
provider_id uuid not null
edition_id uuid not null
stage_id uuid null
external_id text not null
name text not null
number integer null
starts_at timestamptz null
ends_at timestamptz null
source_payload_hash text null
synced_at timestamptz not null default now()
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
version integer not null default 1
```

### FK

```text
provider_id → data_providers.id ON DELETE RESTRICT
edition_id → competition_editions.id ON DELETE CASCADE
stage_id → competition_stages.id ON DELETE SET NULL
```

### Constraints

```text
unique(provider_id, edition_id, external_id)
check(trim(external_id) <> '')
check(trim(name) <> '')
check(number is null or number > 0)
check(starts_at is null or ends_at is null or starts_at <= ends_at)
check(version > 0)
```

### Cross-entity invariant

Se `stage_id` non è null, lo Stage deve appartenere alla stessa Edition.

### Indexes

```text
provider_rounds_edition_idx(edition_id)
provider_rounds_stage_idx(stage_id)
provider_rounds_number_idx(edition_id, number)
provider_rounds_synced_idx(synced_at)
```

### RLS

Inherited visibility from parent Competition.

---

## 2.9 fantagol_rounds

### Purpose

Unità ufficiale di gioco FantaGol.

### Columns

```text
id uuid primary key default gen_random_uuid()
edition_id uuid not null
stage_id uuid null
name text not null
sequence integer not null
target_match_count integer not null
minimum_match_count integer not null
maximum_match_count integer not null
selection_policy text not null
opens_at timestamptz not null
lock_at timestamptz not null
starts_at timestamptz not null
ends_at timestamptz null
status text not null default 'draft'
active boolean not null default true
official_match_set_version integer null
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
version integer not null default 1
```

### FK

```text
edition_id → competition_editions.id ON DELETE CASCADE
stage_id → competition_stages.id ON DELETE SET NULL
```

### Allowed selection_policy

```text
official_matchweek
chronological_first_n
chronological_window
provider_group
manual_admin
balanced_stage
custom_curated
```

### Allowed status

```text
draft
scheduled
predictions_open
predictions_locked
live
partial_finished
waiting_postponed
final_calculable
final_official
recalculated
cancelled
```

### Constraints

```text
unique(edition_id, sequence)
check(trim(name) <> '')
check(sequence > 0)
check(target_match_count > 0)
check(minimum_match_count > 0)
check(maximum_match_count >= minimum_match_count)
check(target_match_count between minimum_match_count and maximum_match_count)
check(opens_at < lock_at)
check(lock_at <= starts_at)
check(ends_at is null or ends_at >= starts_at)
check(official_match_set_version is null or official_match_set_version > 0)
check(version > 0)
```

### Cross-entity invariant

Se `stage_id` non è null, lo Stage deve appartenere alla stessa Edition.

### Indexes

```text
fantagol_rounds_edition_idx(edition_id)
fantagol_rounds_stage_idx(stage_id)
fantagol_rounds_status_idx(status)
fantagol_rounds_active_idx(active)
fantagol_rounds_dates_idx(opens_at, lock_at, starts_at)
fantagol_rounds_current_idx(edition_id, active, status)
```

### RLS

Public/authenticated read only when:

```text
parent Competition visible
AND round status != draft
```

---

## 2.10 fantagol_round_matches

### Purpose

Match Set ordinato del FantaGol Round.

### Columns

```text
id uuid primary key default gen_random_uuid()
fantagol_round_id uuid not null
match_id uuid not null
slot_number integer not null
selection_reason text not null
source_provider_round_id uuid null
required boolean not null default true
included_at timestamptz not null default now()
removed_at timestamptz null
version integer not null default 1
```

### FK

```text
fantagol_round_id → fantagol_rounds.id ON DELETE CASCADE
match_id → matches.id ON DELETE RESTRICT
source_provider_round_id → provider_rounds.id ON DELETE SET NULL
```

### Constraints

```text
unique(fantagol_round_id, match_id)
unique(fantagol_round_id, slot_number)
check(slot_number > 0)
check(trim(selection_reason) <> '')
check(removed_at is null or removed_at >= included_at)
check(version > 0)
```

### Cross-entity invariants

- Match Edition = FantaGol Round Edition.
- `source_provider_round_id`, se valorizzato, appartiene alla stessa Edition.
- `slot_number <= maximum_match_count`.

### Immutability

Dopo stato:

```text
predictions_locked
live
partial_finished
waiting_postponed
final_calculable
final_official
recalculated
```

sono vietati:

```text
INSERT
UPDATE
DELETE
```

salvo procedura amministrativa futura esplicita.

### Indexes

```text
fantagol_round_matches_round_idx(fantagol_round_id)
fantagol_round_matches_match_idx(match_id)
fantagol_round_matches_slot_idx(fantagol_round_id, slot_number)
fantagol_round_matches_required_idx(fantagol_round_id, required)
```

### RLS

Visible only when parent FantaGol Round is visible.

---

## 2.11 match_set_versions

### Purpose

Snapshot immutabile del Match Set.

### Columns

```text
id uuid primary key default gen_random_uuid()
fantagol_round_id uuid not null
version integer not null
match_ids_ordered uuid[] not null
reason text not null
created_by uuid null
created_at timestamptz not null default now()
official boolean not null default false
```

### FK

```text
fantagol_round_id → fantagol_rounds.id ON DELETE CASCADE
created_by → auth.users.id ON DELETE SET NULL
```

### Constraints

```text
unique(fantagol_round_id, version)
unique partial(fantagol_round_id) where official = true
check(version > 0)
check(cardinality(match_ids_ordered) > 0)
check(array_position(match_ids_ordered, null) is null)
check(trim(reason) <> '')
```

### Snapshot validation

Lo snapshot deve:

- contenere solo Match del relativo Round;
- mantenere l'ordine slot;
- non contenere duplicati;
- avere cardinalità uguale al Match Set attivo;
- essere immutabile dopo INSERT.

### RLS

Solo snapshot ufficiali leggibili da client autorizzati.

---

## 2.12 team_aliases

### Purpose

Alias e traduzioni dei Team.

### Columns

```text
id uuid primary key default gen_random_uuid()
team_id uuid not null
locale text not null
alias text not null
alias_type text not null
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
```

### FK

```text
team_id → teams.id ON DELETE CASCADE
```

### Allowed alias_type

```text
official
short
translated
provider
historical
```

### Constraints

```text
unique(team_id, locale, alias, alias_type)
check(trim(locale) <> '')
check(trim(alias) <> '')
```

### Indexes

```text
team_aliases_team_idx(team_id)
team_aliases_locale_idx(locale)
team_aliases_alias_search_idx(lower(alias))
```

### RLS

Public read.

---

## 2.13 competition_audit_log

### Purpose

Audit append-only del Competition Engine.

### Columns

```text
id uuid primary key default gen_random_uuid()
actor_id uuid null
action text not null
aggregate_type text not null
aggregate_id uuid not null
before_json jsonb null
after_json jsonb null
reason text null
correlation_id uuid null
created_at timestamptz not null default now()
```

### FK

```text
actor_id → auth.users.id ON DELETE SET NULL
```

### Constraints

```text
check(trim(action) <> '')
check(trim(aggregate_type) <> '')
```

### Indexes

```text
competition_audit_log_aggregate_idx(aggregate_type, aggregate_id)
competition_audit_log_actor_idx(actor_id)
competition_audit_log_created_idx(created_at)
competition_audit_log_correlation_idx(correlation_id)
```

### RLS

Service/admin only.

### Immutability

No UPDATE or DELETE through client paths.

---

# 3. LEGACY TABLE EXTENSIONS

## 3.1 teams

### Existing columns preserved

```text
id
name
short_name
logo_url
created_at
```

### New columns

```text
sport_id uuid null
team_type text not null default 'club'
code text null
country_code text null
federation_code text null
crest_reference text null
active boolean not null default true
updated_at timestamptz not null default now()
version integer not null default 1
```

### FK

```text
sport_id → sports.id ON DELETE RESTRICT
```

### Allowed team_type

```text
club
national_team
```

### Constraints

```text
check(version > 0)
```

### Backfill

Tutti i Team legacy:

```text
sport_id = football
team_type = club
```

salvo successive correzioni amministrative.

---

## 3.2 matches

### Existing columns preserved

```text
id
season_id
matchday_id
home_team_id
away_team_id
kickoff
home_score
away_score
status
created_at
```

### New columns

```text
edition_id uuid null
stage_id uuid null
provider_round_id uuid null
venue_name text null
minute integer null
period text null
provider_updated_at timestamptz null
finalised_at timestamptz null
active boolean not null default true
updated_at timestamptz not null default now()
version integer not null default 1
```

### FK

```text
edition_id → competition_editions.id ON DELETE RESTRICT
stage_id → competition_stages.id ON DELETE SET NULL
provider_round_id → provider_rounds.id ON DELETE SET NULL
```

### Constraints

```text
check(home_team_id <> away_team_id)
check(home_score is null or home_score >= 0)
check(away_score is null or away_score >= 0)
check(minute is null or minute between 0 and 150)
check(version > 0)
check(
  status not in ('finished','awarded')
  or (home_score is not null and away_score is not null)
)
```

### Cross-entity invariants

- `stage_id`, se valorizzato, appartiene a `edition_id`.
- `provider_round_id`, se valorizzato, appartiene a `edition_id`.
- Team casa e trasferta devono appartenere alla stessa Edition tramite `competition_teams`, quando `edition_id` è valorizzata.

### Indexes

```text
matches_edition_idx(edition_id)
matches_stage_idx(stage_id)
matches_provider_round_idx(provider_round_id)
matches_kickoff_idx(kickoff)
matches_status_idx(status)
matches_active_idx(active)
matches_live_idx(status, kickoff)
```

---

# 4. SHARED FUNCTIONS

## 4.1 set_updated_at()

Trigger function:

```text
new.updated_at = now()
```

## 4.2 increment_row_version()

Trigger function:

```text
new.version = old.version + 1
```

## 4.3 validate_stage_edition_consistency()

Garantisce coerenza Edition/Stage.

## 4.4 validate_provider_round_edition_consistency()

Garantisce coerenza Edition/Provider Round.

## 4.5 validate_match_edition_consistency()

Garantisce coerenza tra Match, Stage e Provider Round.

## 4.6 validate_round_match_consistency()

Garantisce:

- stessa Edition;
- Provider Round coerente;
- slot entro limite;
- Match attivo.

## 4.7 protect_fantagol_round_match_after_lock()

Blocca INSERT/UPDATE/DELETE dopo lock.

## 4.8 validate_match_set_snapshot()

Valida snapshot Match Set.

## 4.9 protect_match_set_version_immutability()

Blocca UPDATE/DELETE di snapshot.

## 4.10 sync_official_match_set_version()

Aggiorna:

```text
fantagol_rounds.official_match_set_version
```

quando una versione diventa ufficiale.

---

# 5. PURE HELPERS

## 5.1 get_round_match_count(round_id)

Return:

```text
integer
```

Conta Match Set attivo.

## 5.2 compute_round_lock_at(round_id)

Return:

```text
min(match.kickoff)
```

## 5.3 compute_round_capabilities(round_id)

Return:

```text
supports_points_pure = match_count >= 1
supports_fantacalcio = match_count = 10
supports_one_to_one = match_count = 10
```

## 5.4 validate_fantagol_round_structure(round_id)

Return:

```text
valid boolean
error_codes text[]
match_count integer
```

Errori minimi:

```text
ROUND_NOT_FOUND
ROUND_MATCH_COUNT_INVALID
ROUND_DUPLICATE_MATCH
ROUND_SLOT_SEQUENCE_INVALID
ROUND_MATCH_EDITION_MISMATCH
ROUND_MATCH_CANCELLED
ROUND_KICKOFF_MISSING
ROUND_DATES_INVALID
```

---

# 6. READ MODELS

## 6.1 active_competitions_view

Mostra Competition pubbliche abilitate.

## 6.2 competition_edition_overview_view

Campi:

```text
edition_id
competition_id
competition_code
label
status
starts_at
ends_at
stage_count
team_count
match_count
```

## 6.3 current_fantagol_round_view

Regola:

Per ogni Edition mostra al massimo un Round corrente, scelto deterministicamente per:

```text
status priority
starts_at
sequence
```

Non mostra:

```text
draft
final_official
recalculated
cancelled
```

## 6.4 round_match_set_view

Campi:

```text
round_id
slot_number
match_id
kickoff
home_team_id
home_team_name
away_team_id
away_team_name
status
home_score
away_score
required
```

## 6.5 upcoming_matches_view

Mostra Match attivi futuri o rinviati.

## 6.6 competition_calendar_view

Mostra calendario completo normalizzato.

Tutte le view:

```text
security_invoker = true
```

---

# 7. RLS MATRIX

| Object | anon SELECT | authenticated SELECT | client WRITE | service_role |
|---|---:|---:|---:|---:|
| sports | active | active | no | full |
| competitions | enabled + public | enabled | no | full |
| competition_editions | public parent | enabled parent | no | full |
| competition_stages | public parent | enabled parent | no | full |
| competition_teams | public parent | enabled parent | no | full |
| data_providers | no | no | no | full |
| provider_entity_maps | no | no | no | full |
| provider_rounds | public parent | enabled parent | no | full |
| fantagol_rounds | visible + not draft | visible + not draft | no | full |
| fantagol_round_matches | visible round | visible round | no | full |
| match_set_versions | official + visible round | official + visible round | no | full |
| team_aliases | yes | yes | no | full |
| competition_audit_log | no | no | no | full |

---

# 8. GRANT POLICY

## 8.1 anon/authenticated

Solo:

```text
SELECT su tabelle pubbliche autorizzate
SELECT su read views
EXECUTE su pure helper strettamente necessari
```

## 8.2 service_role

Full access agli oggetti Foundation.

## 8.3 PUBLIC

Revocare EXECUTE da `PUBLIC` per tutte le funzioni custom.

---

# 9. TRIGGER MAP

## updated_at

Applicato a:

```text
sports
competitions
competition_editions
competition_stages
competition_teams
data_providers
provider_entity_maps
provider_rounds
teams
matches
fantagol_rounds
team_aliases
```

## version increment

Applicato a:

```text
sports
competitions
competition_editions
competition_stages
provider_rounds
teams
matches
fantagol_rounds
fantagol_round_matches
```

## consistency triggers

Applicati a:

```text
provider_rounds
matches
fantagol_rounds
fantagol_round_matches
match_set_versions
```

---

# 10. SEED FOUNDATION

La Foundation Migration inserisce solo:

## sports

```text
football
```

## competitions

```text
serie_a
```

## Non inserisce

```text
Competition Edition 2026/27
Stage
Team
Provider reale
Provider Round
Match
FantaGol Round
```

Questi dati appartengono a seed o migration operative successive.

---

# 11. PRE-FLIGHT

La Foundation Migration deve interrompersi se manca una delle tabelle legacy:

```text
teams
matches
seasons
matchdays
predictions
```

Deve inoltre verificare:

```text
home_team_id != away_team_id per tutti i Match esistenti
score legacy non negativi
minute, se già presente, entro 0..150
```

La migration resta interamente transazionale.

---

# 12. ROLLBACK

Il rollback deve:

1. eliminare view;
2. eliminare trigger su tabelle legacy;
3. eliminare nuove tabelle in ordine FK;
4. eliminare vincoli e indici aggiunti a `matches`;
5. eliminare colonne aggiunte a `matches`;
6. eliminare vincoli e indici aggiunti a `teams`;
7. eliminare colonne aggiunte a `teams`;
8. eliminare funzioni Foundation;
9. non toccare dati o colonne legacy originarie.

---

# 13. OBJECTS ESPLICITAMENTE FUORI SCOPE

Non devono comparire nella Foundation Migration:

```text
league_modes
league_fixtures
fantacalcio_allocations
one_to_one_matrix_entries
prediction_snapshots
prediction_score_results
standings
domain_events
command_logs
pass_wallets
pass_transactions
control_room_access_sessions
```

---

# 14. ACCEPTANCE CRITERIA

Il Blueprint è approvato quando:

- [ ] nessun oggetto è Serie A specifico;
- [ ] nessun provider è hardcoded;
- [ ] legacy preservato;
- [ ] Edition/Stage/Provider Round coerenti;
- [ ] Match Set immutabile dopo lock;
- [ ] snapshot Match Set immutabile;
- [ ] RLS default deny;
- [ ] read model coerenti;
- [ ] rollback completo;
- [ ] seed minimo;
- [ ] nessuna logica Strategy prematura;
- [ ] supporto club e nazionali;
- [ ] supporto campionati, coppe, gironi e knockout;
- [ ] futura Premier League senza schema change;
- [ ] futura Champions League senza schema change;
- [ ] build web non impattata.

---

# 15. DECISIONI CONGELATE

1. `Competition Edition` sostituisce concettualmente `seasons`.
2. `Provider Round` e `FantaGol Round` sono entità distinte.
3. `matchdays` resta legacy-supported.
4. `teams` e `matches` vengono estese, non duplicate.
5. Il Match Set è esplicito.
6. Il Match Set è versionato.
7. Il lock è sul FantaGol Round.
8. Le strategie arriveranno in migration successiva.
9. Le scritture client dirette sono vietate.
10. I Provider ID non entrano nel dominio canonico.
11. Le view usano `security_invoker`.
12. Gli snapshot ufficiali sono immutabili.
13. Il database è provider-agnostic e international-ready.

---

# 16. DIRETTIVA FINALE

La versione RELEASE di:

```text
001_foundation_competition_core.sql
001_foundation_competition_core_rollback.sql
```

deve implementare esattamente questo Blueprint.

Qualsiasi deviazione richiede aggiornamento esplicito e approvazione del Blueprint prima della migration.
