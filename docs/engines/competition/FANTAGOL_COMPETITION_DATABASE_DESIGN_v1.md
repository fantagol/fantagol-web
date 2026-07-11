# FANTAGOL COMPETITION DATABASE DESIGN v1

**Stato:** design freeze candidate  
**Ambito:** schema dati del Competition Engine  
**Obiettivo:** definire in modo completo tabelle, chiavi, vincoli, indici, RLS, RPC e read model prima della migration `002_competition_core.sql`.

---

# 0. PRINCIPI DI PROGETTAZIONE

## 0.1 Database autorevole

Le invarianti strutturali devono essere garantite dal database quando tecnicamente possibile.

Esempi:

- unicità;
- integrità referenziale;
- valori ammessi;
- impossibilità di duplicare match o slot;
- consistenza temporale;
- impossibilità di usare la stessa squadra come casa e trasferta;
- impossibilità di creare un round con limiti incoerenti.

## 0.2 Migrazione non distruttiva

La migration deve convivere con:

```text
seasons
matchdays
teams
matches
predictions
leagues
league_members
clubs
profiles
```

Nessuna tabella legacy viene rinominata o eliminata nella prima fase.

## 0.3 Naming

Nomi tecnici in inglese e coerenti con il Domain Dictionary.

## 0.4 Timestamp

Tutti i timestamp sono `timestamptz` e salvati in UTC.

## 0.5 UUID

Tutte le nuove entità principali usano UUID.

Default raccomandato:

```sql
gen_random_uuid()
```

## 0.6 Versioning

Le entità critiche includono:

```text
version integer not null default 1
updated_at timestamptz not null default now()
```

## 0.7 Soft state

Le entità principali usano `active boolean` o stato esplicito invece di delete fisico quando possibile.

---

# 1. ENUM E DOMINI LOGICI

Per ridurre accoppiamento e facilitare evoluzioni, la migration v1 può usare `text + check constraint` invece di enum PostgreSQL irreversibili.

Valori ufficiali:

```text
competition_type:
- league
- domestic_cup
- continental_club
- national_team_tournament
- qualifier
- super_cup
- friendly_tournament

competition_scope:
- domestic
- continental
- international

competition_gender:
- male
- female
- mixed

edition_status:
- draft
- scheduled
- active
- completed
- archived
- cancelled

stage_type:
- regular_season
- league_phase
- group_stage
- playoff
- round_of_32
- round_of_16
- quarter_final
- semi_final
- final
- qualifier

team_type:
- club
- national_team

match_status:
- scheduled
- postponed
- cancelled
- live_first_half
- halftime
- live_second_half
- extra_time
- penalties
- finished
- awarded
- abandoned

round_status:
- draft
- scheduled
- predictions_open
- predictions_locked
- live
- partial_finished
- waiting_postponed
- final_calculable
- final_official
- recalculated
- cancelled

selection_policy:
- official_matchweek
- chronological_first_n
- chronological_window
- provider_group
- manual_admin
- balanced_stage
- custom_curated

alias_type:
- official
- short
- translated
- provider
- historical
```

---

# 2. TABLE: sports

## 2.1 Purpose

Registro degli sport supportati.

## 2.2 Columns

```text
id uuid primary key
code text not null
name_key text not null
active boolean not null default true
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
version integer not null default 1
```

## 2.3 Constraints

```text
PK: id
UNIQUE: code
CHECK: code <> ''
CHECK: name_key <> ''
CHECK: version > 0
```

## 2.4 Indexes

```text
sports_active_idx(active)
```

## 2.5 RLS

Public read only for active rows.

Write only service role / admin controlled path.

---

# 3. TABLE: competitions

## 3.1 Purpose

Registro universale delle competizioni reali.

## 3.2 Columns

```text
id uuid primary key
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

## 3.3 Foreign Keys

```text
sport_id → sports.id
ON DELETE RESTRICT
```

## 3.4 Constraints

```text
UNIQUE: code
CHECK: trim(code) <> ''
CHECK: trim(name_key) <> ''
CHECK: competition_type in allowed values
CHECK: scope in allowed values
CHECK: gender in allowed values
CHECK: priority >= 0
CHECK: version > 0
```

## 3.5 Indexes

```text
competitions_sport_idx(sport_id)
competitions_enabled_public_idx(enabled, public)
competitions_priority_idx(priority)
competitions_country_idx(country_code)
```

## 3.6 RLS

Public read:

```text
enabled = true and public = true
```

Authenticated read:

```text
enabled = true
```

Write only controlled backend.

---

# 4. TABLE: competition_editions

## 4.1 Purpose

Stagione o edizione specifica di una competizione.

## 4.2 Columns

```text
id uuid primary key
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

## 4.3 Foreign Keys

```text
competition_id → competitions.id
ON DELETE RESTRICT
```

## 4.4 Constraints

```text
UNIQUE: (competition_id, label)
CHECK: trim(label) <> ''
CHECK: year_start between 1900 and 2200
CHECK: year_end is null or year_end between year_start and year_start + 2
CHECK: starts_at < ends_at
CHECK: status in allowed values
CHECK: version > 0
```

## 4.5 Indexes

```text
competition_editions_competition_idx(competition_id)
competition_editions_status_idx(status)
competition_editions_active_idx(active)
competition_editions_dates_idx(starts_at, ends_at)
```

## 4.6 RLS

Read allowed when parent Competition is enabled.

Write only controlled backend.

---

# 5. TABLE: competition_stages

## 5.1 Purpose

Fase interna di una Competition Edition.

## 5.2 Columns

```text
id uuid primary key
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

## 5.3 Foreign Keys

```text
edition_id → competition_editions.id
ON DELETE CASCADE
```

## 5.4 Constraints

```text
UNIQUE: (edition_id, code)
UNIQUE: (edition_id, sequence)
CHECK: trim(code) <> ''
CHECK: trim(name_key) <> ''
CHECK: stage_type in allowed values
CHECK: sequence > 0
CHECK: starts_at is null or ends_at is null or starts_at < ends_at
CHECK: version > 0
```

## 5.5 Indexes

```text
competition_stages_edition_idx(edition_id)
competition_stages_type_idx(stage_type)
competition_stages_active_idx(active)
```

## 5.6 RLS

Public read through enabled parent Competition.

Write only controlled backend.

---

# 6. TABLE: competition_teams

## 6.1 Purpose

Relazione tra Team legacy/interno e Competition Edition.

Nota di compatibilità:

La tabella legacy `teams` viene preservata e riusata nella fase iniziale.

## 6.2 Columns

```text
id uuid primary key
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

## 6.3 Foreign Keys

```text
edition_id → competition_editions.id
ON DELETE CASCADE

team_id → teams.id
ON DELETE RESTRICT
```

## 6.4 Constraints

```text
UNIQUE: (edition_id, team_id)
CHECK: seed is null or seed > 0
CHECK: left_at is null or left_at >= joined_at
```

## 6.5 Indexes

```text
competition_teams_edition_idx(edition_id)
competition_teams_team_idx(team_id)
competition_teams_group_idx(edition_id, group_code)
```

## 6.6 RLS

Public read when edition is public.

Write only controlled backend.

---

# 7. ALTER TABLE: teams

## 7.1 Purpose

Estendere la tabella legacy senza romperla.

## 7.2 New Columns

```text
sport_id uuid null
team_type text not null default 'club'
code text null
short_name text null
country_code text null
federation_code text null
crest_reference text null
active boolean not null default true
updated_at timestamptz not null default now()
version integer not null default 1
```

## 7.3 Foreign Keys

```text
sport_id → sports.id
ON DELETE RESTRICT
```

## 7.4 Constraints

```text
CHECK: team_type in ('club','national_team')
CHECK: version > 0
```

## 7.5 Indexes

```text
teams_sport_idx(sport_id)
teams_type_idx(team_type)
teams_country_idx(country_code)
teams_active_idx(active)
```

## 7.6 Compatibility

La colonna legacy `name` resta invariata.

La unique globale su `name` resta temporaneamente attiva.

---

# 8. TABLE: data_providers

## 8.1 Purpose

Registro interno dei provider.

## 8.2 Columns

```text
id uuid primary key
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

## 8.3 Constraints

```text
UNIQUE: code
CHECK: trim(code) <> ''
CHECK: trim(name) <> ''
CHECK: provider_type in ('calendar','live_score','odds','multi')
CHECK: priority >= 0
CHECK: rate_limit_per_minute is null or rate_limit_per_minute > 0
```

## 8.4 Indexes

```text
data_providers_active_priority_idx(active, priority)
```

## 8.5 RLS

Public read not required.

Authenticated read optional.

Write only controlled backend.

---

# 9. TABLE: provider_entity_maps

## 9.1 Purpose

Mapping tra ID interni e ID provider.

## 9.2 Columns

```text
id uuid primary key
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

## 9.3 Foreign Keys

```text
provider_id → data_providers.id
ON DELETE CASCADE
```

## 9.4 Constraints

```text
UNIQUE: (provider_id, entity_type, external_id)
UNIQUE: (provider_id, entity_type, internal_id)
CHECK: entity_type in ('competition','edition','stage','team','provider_round','match')
CHECK: trim(external_id) <> ''
```

## 9.5 Indexes

```text
provider_entity_maps_internal_idx(entity_type, internal_id)
provider_entity_maps_external_idx(provider_id, entity_type, external_id)
provider_entity_maps_active_idx(active)
```

## 9.6 RLS

No public read.

Service role only.

---

# 10. TABLE: provider_rounds

## 10.1 Purpose

Turni così come restituiti dal provider.

## 10.2 Columns

```text
id uuid primary key
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

## 10.3 Foreign Keys

```text
provider_id → data_providers.id
ON DELETE RESTRICT

edition_id → competition_editions.id
ON DELETE CASCADE

stage_id → competition_stages.id
ON DELETE SET NULL
```

## 10.4 Constraints

```text
UNIQUE: (provider_id, external_id)
CHECK: trim(external_id) <> ''
CHECK: trim(name) <> ''
CHECK: number is null or number > 0
CHECK: starts_at is null or ends_at is null or starts_at <= ends_at
CHECK: version > 0
```

## 10.5 Indexes

```text
provider_rounds_edition_idx(edition_id)
provider_rounds_stage_idx(stage_id)
provider_rounds_number_idx(edition_id, number)
provider_rounds_synced_idx(synced_at)
```

## 10.6 RLS

Public read through enabled competition.

Write only controlled backend.

---

# 11. ALTER TABLE: matches

## 11.1 Purpose

Estendere la tabella legacy per il modello universale.

## 11.2 New Columns

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

## 11.3 Foreign Keys

```text
edition_id → competition_editions.id
ON DELETE RESTRICT

stage_id → competition_stages.id
ON DELETE SET NULL

provider_round_id → provider_rounds.id
ON DELETE SET NULL
```

## 11.4 Constraints

```text
CHECK: home_team_id <> away_team_id
CHECK: minute is null or minute >= 0
CHECK: version > 0
CHECK:
  status not in ('finished','awarded')
  or (home_score is not null and away_score is not null)
```

## 11.5 Indexes

```text
matches_edition_idx(edition_id)
matches_stage_idx(stage_id)
matches_provider_round_idx(provider_round_id)
matches_kickoff_idx(kickoff)
matches_status_idx(status)
matches_active_idx(active)
matches_live_idx(status, kickoff)
```

## 11.6 Compatibility

Restano:

```text
season_id
matchday_id
```

Verranno popolati e mantenuti durante la fase transitoria.

---

# 12. TABLE: fantagol_rounds

## 12.1 Purpose

Unità ufficiale di gioco.

## 12.2 Columns

```text
id uuid primary key
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
official_match_set_version integer not null default 1
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
version integer not null default 1
```

## 12.3 Foreign Keys

```text
edition_id → competition_editions.id
ON DELETE CASCADE

stage_id → competition_stages.id
ON DELETE SET NULL
```

## 12.4 Constraints

```text
UNIQUE: (edition_id, sequence)
CHECK: trim(name) <> ''
CHECK: sequence > 0
CHECK: target_match_count > 0
CHECK: minimum_match_count > 0
CHECK: maximum_match_count >= minimum_match_count
CHECK: target_match_count between minimum_match_count and maximum_match_count
CHECK: opens_at < lock_at
CHECK: lock_at <= starts_at
CHECK: ends_at is null or ends_at >= starts_at
CHECK: status in allowed values
CHECK: selection_policy in allowed values
CHECK: official_match_set_version > 0
CHECK: version > 0
```

## 12.5 Indexes

```text
fantagol_rounds_edition_idx(edition_id)
fantagol_rounds_stage_idx(stage_id)
fantagol_rounds_status_idx(status)
fantagol_rounds_active_idx(active)
fantagol_rounds_dates_idx(opens_at, lock_at, starts_at)
fantagol_rounds_current_idx(edition_id, active, status)
```

## 12.6 RLS

Public read when parent Competition is public.

Write only controlled backend.

---

# 13. TABLE: fantagol_round_matches

## 13.1 Purpose

Match Set ordinato di un FantaGol Round.

## 13.2 Columns

```text
id uuid primary key
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

## 13.3 Foreign Keys

```text
fantagol_round_id → fantagol_rounds.id
ON DELETE CASCADE

match_id → matches.id
ON DELETE RESTRICT

source_provider_round_id → provider_rounds.id
ON DELETE SET NULL
```

## 13.4 Constraints

```text
UNIQUE: (fantagol_round_id, match_id)
UNIQUE: (fantagol_round_id, slot_number)
CHECK: slot_number > 0
CHECK: trim(selection_reason) <> ''
CHECK: removed_at is null or removed_at >= included_at
CHECK: version > 0
```

## 13.5 Indexes

```text
fantagol_round_matches_round_idx(fantagol_round_id)
fantagol_round_matches_match_idx(match_id)
fantagol_round_matches_slot_idx(fantagol_round_id, slot_number)
fantagol_round_matches_required_idx(fantagol_round_id, required)
```

## 13.6 RLS

Public read through visible round.

Write only controlled backend.

---

# 14. TABLE: match_set_versions

## 14.1 Purpose

Snapshot versionato del Match Set.

## 14.2 Columns

```text
id uuid primary key
fantagol_round_id uuid not null
version integer not null
match_ids_ordered uuid[] not null
reason text not null
created_by uuid null
created_at timestamptz not null default now()
official boolean not null default false
```

## 14.3 Foreign Keys

```text
fantagol_round_id → fantagol_rounds.id
ON DELETE CASCADE

created_by → auth.users.id
ON DELETE SET NULL
```

## 14.4 Constraints

```text
UNIQUE: (fantagol_round_id, version)
CHECK: version > 0
CHECK: cardinality(match_ids_ordered) > 0
CHECK: trim(reason) <> ''
```

## 14.5 Indexes

```text
match_set_versions_round_idx(fantagol_round_id)
match_set_versions_official_idx(fantagol_round_id, official)
```

## 14.6 RLS

Public read only for official rows.

Write only controlled backend.

---

# 15. TABLE: team_aliases

## 15.1 Purpose

Alias, traduzioni e nomi provider dei Team.

## 15.2 Columns

```text
id uuid primary key
team_id uuid not null
locale text not null
alias text not null
alias_type text not null
created_at timestamptz not null default now()
updated_at timestamptz not null default now()
```

## 15.3 Foreign Keys

```text
team_id → teams.id
ON DELETE CASCADE
```

## 15.4 Constraints

```text
UNIQUE: (team_id, locale, alias, alias_type)
CHECK: trim(locale) <> ''
CHECK: trim(alias) <> ''
CHECK: alias_type in allowed values
```

## 15.5 Indexes

```text
team_aliases_team_idx(team_id)
team_aliases_locale_idx(locale)
team_aliases_alias_search_idx(lower(alias))
```

## 15.6 RLS

Public read.

Write only controlled backend.

---

# 16. TABLE: competition_audit_log

## 16.1 Purpose

Audit immutabile delle operazioni amministrative e provider rilevanti.

## 16.2 Columns

```text
id uuid primary key
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

## 16.3 Foreign Keys

```text
actor_id → auth.users.id
ON DELETE SET NULL
```

## 16.4 Constraints

```text
CHECK: trim(action) <> ''
CHECK: trim(aggregate_type) <> ''
```

## 16.5 Indexes

```text
competition_audit_log_aggregate_idx(aggregate_type, aggregate_id)
competition_audit_log_actor_idx(actor_id)
competition_audit_log_created_idx(created_at)
competition_audit_log_correlation_idx(correlation_id)
```

## 16.6 RLS

No public read.

Admin/service only.

---

# 17. TRIGGER GENERALI

## 17.1 updated_at trigger

Funzione riusabile:

```text
set_updated_at()
```

Applicata a:

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

## 17.2 version increment trigger

Funzione riusabile:

```text
increment_row_version()
```

Applicata alle entità con `version`.

## 17.3 Match Set freeze trigger

Vietare UPDATE/DELETE su `fantagol_round_matches` quando il round è:

```text
predictions_locked
live
partial_finished
waiting_postponed
final_calculable
final_official
recalculated
```

Eccezione:

- service role;
- procedura amministrativa dedicata;
- audit obbligatorio.

## 17.4 Match Set version consistency

Quando viene marcata una `match_set_versions` come official:

- una sola versione official per round;
- aggiornare `fantagol_rounds.official_match_set_version`.

---

# 18. FUNZIONI DATABASE PURE

## 18.1 validate_fantagol_round_structure(round_id)

Controlla:

- count;
- duplicati;
- slot consecutivi;
- edition mismatch;
- kickoff;
- match cancelled;
- coerenza temporale.

Return:

```text
valid boolean
error_codes text[]
match_count integer
```

## 18.2 compute_round_lock_at(round_id)

Return:

```text
min(kickoff)
```

## 18.3 compute_round_capabilities(round_id)

Return:

```text
supports_points_pure boolean
supports_fantacalcio boolean
supports_one_to_one boolean
```

## 18.4 get_round_match_count(round_id)

Return integer.

---

# 19. RPC PREVISTE

Non tutte vengono create nella migration iniziale.

## 19.1 Read RPC

```text
get_active_competitions_rpc()
get_current_fantagol_round_rpc(competition_id)
get_fantagol_round_matches_rpc(round_id)
get_competition_calendar_rpc(edition_id)
```

## 19.2 Admin RPC

```text
create_fantagol_round_rpc(...)
approve_match_set_rpc(...)
replace_match_before_lock_rpc(...)
open_round_rpc(round_id)
lock_round_rpc(round_id)
cancel_round_rpc(round_id, reason)
```

## 19.3 Service-only RPC

```text
upsert_provider_round_rpc(...)
upsert_match_from_provider_rpc(...)
sync_competition_calendar_rpc(...)
```

## 19.4 Security

Ogni RPC `SECURITY DEFINER` deve:

- `SET search_path TO public`;
- validare `auth.uid()` quando user-facing;
- essere revocata da `PUBLIC`;
- avere grant esplicito;
- produrre audit;
- usare error code stabili.

---

# 20. READ MODELS

## 20.1 active_competitions_view

Campi:

```text
competition_id
code
name_key
country_code
competition_type
scope
beta
launch_date
priority
```

## 20.2 competition_edition_overview_view

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

## 20.3 current_fantagol_round_view

Campi:

```text
round_id
edition_id
competition_id
name
sequence
status
opens_at
lock_at
starts_at
ends_at
match_count
supports_points_pure
supports_fantacalcio
supports_one_to_one
```

## 20.4 round_match_set_view

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

## 20.5 upcoming_matches_view

Campi:

```text
competition_id
edition_id
stage_id
match_id
kickoff
home_team
away_team
status
```

## 20.6 competition_calendar_view

Campi:

```text
competition_id
edition_id
provider_round_id
provider_round_number
match_id
kickoff
home_team
away_team
status
score
```

---

# 21. RLS MATRIX

| Table | anon SELECT | authenticated SELECT | client INSERT/UPDATE/DELETE |
|---|---:|---:|---:|
| sports | active only | active only | no |
| competitions | enabled + public | enabled | no |
| competition_editions | public parent | enabled parent | no |
| competition_stages | public parent | enabled parent | no |
| competition_teams | public parent | enabled parent | no |
| data_providers | no | limited optional | no |
| provider_entity_maps | no | no | no |
| provider_rounds | public parent | enabled parent | no |
| teams | active | active | no |
| matches | public competition | enabled competition | no |
| fantagol_rounds | public competition | enabled competition | no |
| fantagol_round_matches | visible round | visible round | no |
| match_set_versions | official only | official only | no |
| team_aliases | yes | yes | no |
| competition_audit_log | no | admin only | no |

---

# 22. INDEX STRATEGY

Indici obbligatori per query operative:

```text
matches(status, kickoff)
matches(edition_id, kickoff)
fantagol_rounds(edition_id, status)
fantagol_rounds(lock_at)
fantagol_round_matches(fantagol_round_id, slot_number)
provider_entity_maps(provider_id, entity_type, external_id)
provider_rounds(edition_id, number)
competition_teams(edition_id, team_id)
```

Indici JSONB non necessari nella v1.

---

# 23. LEGACY BRIDGE

## 23.1 seasons → competition_editions

Aggiungere in futuro:

```text
seasons.competition_edition_id uuid null
```

Non obbligatorio nella prima sotto-migration se il rischio è elevato.

## 23.2 matchdays → fantagol_rounds/provider_rounds

Aggiungere in futuro:

```text
matchdays.provider_round_id uuid null
matchdays.fantagol_round_id uuid null
```

## 23.3 matches

Le nuove FK convivono con:

```text
season_id
matchday_id
```

## 23.4 predictions

Restano collegate a `matches`.

Il futuro collegamento a `fantagol_round_id` verrà introdotto nel Prediction Engine.

---

# 24. SEED MINIMO

La migration non deve hardcodare l'intero calendario.

Seed minimo:

```text
sports:
- football

competitions:
- serie_a

competition_editions:
- Serie A 2026/27

competition_stages:
- regular_season

data_providers:
- placeholder primary calendar provider
```

I Team e il calendario saranno caricati da seed dedicato o Provider Engine.

---

# 25. ROLLBACK DESIGN

Il rollback deve:

1. rimuovere trigger nuovi;
2. rimuovere view nuove;
3. rimuovere funzioni nuove;
4. rimuovere policy RLS nuove;
5. rimuovere tabelle nuove in ordine FK;
6. rimuovere colonne aggiunte a `matches`;
7. rimuovere colonne aggiunte a `teams`;
8. non toccare dati legacy originari.

Ordine di drop indicativo:

```text
competition_audit_log
team_aliases
match_set_versions
fantagol_round_matches
fantagol_rounds
provider_rounds
provider_entity_maps
data_providers
competition_teams
competition_stages
competition_editions
competitions
sports
```

---

# 26. MIGRATION SPLIT RACCOMANDATO

Per ridurre il rischio:

```text
002a_competition_registry.sql
002b_provider_registry.sql
002c_match_extension.sql
002d_fantagol_rounds.sql
002e_competition_views_rls.sql
```

Se si preferisce mantenere un singolo file logico:

```text
002_competition_core.sql
```

deve essere organizzato in sezioni transazionali chiaramente marcate.

Raccomandazione operativa:

```text
usare 002_competition_core.sql
ma con blocchi interni modulari
```

per mantenere semplice la cronologia iniziale.

---

# 27. ACCEPTANCE CHECKLIST

Il design è congelabile quando:

- [ ] nessuna tabella è Serie A specifica;
- [ ] nessun provider è hardcoded nel dominio;
- [ ] legacy preservato;
- [ ] tutte le FK definite;
- [ ] tutte le unique definite;
- [ ] tutti i check definiti;
- [ ] RLS definita;
- [ ] read model definiti;
- [ ] rollback definito;
- [ ] seed minimo definito;
- [ ] match set immutabile dopo lock;
- [ ] round capability calcolabile;
- [ ] futuro supporto Premier League senza schema change;
- [ ] supporto club e nazionali;
- [ ] supporto campionati e coppe.

---

# 28. DECISIONI CONGELATE

1. Le tabelle legacy restano.
2. `teams` e `matches` vengono estese, non duplicate.
3. `Competition Edition` è la nuova unità stagionale.
4. `Provider Round` e `FantaGol Round` restano distinti.
5. Il Match Set è esplicito e versionato.
6. Il lock dipende dal primo kickoff.
7. I client non scrivono direttamente sul Competition Engine.
8. Tutte le nuove tabelle hanno RLS.
9. Gli ID provider vivono in mapping separati.
10. L'aggiunta futura di nuove competizioni non richiede nuove tabelle.

---

# 29. DIRETTIVA FINALE

La migration `002_competition_core.sql` deve essere una traduzione meccanica di questo design.

Qualsiasi deviazione deve essere motivata prima dell'esecuzione su Supabase.
