# FANTAGOL FOUNDATION DATABASE MASTER v1

**Stato:** documento fondativo  
**Ambito:** costituzione tecnica del database FantaGol  
**Obiettivo:** definire principi, responsabilità, invarianti e regole permanenti per tutte le future migration, tabelle, RPC, view, trigger, policy RLS e procedure amministrative.

---

# 0. SCOPO

Questo documento governa l'evoluzione del database FantaGol.

Non descrive una singola migration.

Definisce invece le regole che ogni migration deve rispettare.

Ordine di autorità:

```text
REGOLAMENTO UFFICIALE
        ↓
DOMAIN DICTIONARY
        ↓
GAME ENGINE MASTER
        ↓
CORE ENGINE MASTER
        ↓
FOUNDATION DATABASE MASTER
        ↓
ENGINE DATABASE DESIGN
        ↓
MIGRATION SQL
        ↓
RPC / VIEW / API
```

Quando una migration contraddice questo documento, la migration è da considerarsi errata.

---

# 1. PRINCIPI FONDATIVI

## 1.1 Database autorevole

Il database è l'autorità finale per:

- identità;
- integrità;
- unicità;
- vincoli;
- stato ufficiale;
- versionamento;
- audit;
- accesso ai dati;
- risultati persistiti.

La UI non è autorevole.

Il client non è autorevole.

Il provider non è autorevole.

## 1.2 Dominio prima dello schema

Ogni nuova tabella nasce da un'entità o da una relazione definita nel Domain Dictionary.

Sequenza obbligatoria:

```text
concetto
→ definizione dominio
→ responsabilità
→ ownership Engine
→ design database
→ migration
```

## 1.3 International Ready

Nessuna nuova tabella deve dipendere da:

- Serie A;
- Italia;
- lingua italiana;
- singola stagione;
- singolo provider;
- singolo formato di competizione.

## 1.4 Provider agnostic

Gli ID provider non sono mai chiavi primarie del dominio.

Gli ID provider vivono in mapping dedicati.

## 1.5 Non distruttività

Le migration iniziali devono preferire:

- add column;
- add table;
- add index;
- add constraint;
- data backfill;
- compatibility bridge.

Evitare:

- drop table;
- rename distruttivi;
- alter type irreversibili;
- conversioni senza rollback.

## 1.6 Riproducibilità

Il database deve poter essere ricostruito da zero tramite migration ordinate e versionate.

## 1.7 Auditabilità

Ogni azione amministrativa o ricalcolo rilevante deve essere tracciabile.

## 1.8 Idempotenza

Le operazioni critiche devono poter essere ritentate senza duplicare effetti.

---

# 2. CLASSIFICAZIONE DEGLI OGGETTI

## 2.1 Entity

Oggetto con identità autonoma.

Esempi:

```text
User
Profile
Club
League
Competition
CompetitionEdition
CompetitionStage
Team
Match
FantaGolRound
Prediction
LeagueFixture
PassTransaction
```

Caratteristiche:

- UUID;
- lifecycle;
- timestamp;
- eventualmente version;
- ownership Engine.

## 2.2 Value Object

Oggetto senza identità autonoma.

Esempi:

```text
score
locale
timezone
color
odds probability
strategy modifier
```

Può essere rappresentato come:

- colonne;
- composite logico;
- jsonb controllato;
- tipo TypeScript.

## 2.3 Relation Entity

Relazione con attributi propri.

Esempi:

```text
league_members
competition_teams
fantagol_round_matches
league_modes
```

## 2.4 Snapshot

Fotografia immutabile.

Esempi:

```text
prediction_snapshot
match_set_version
standing_snapshot
aggregated_odds_snapshot
```

## 2.5 Event

Fatto già avvenuto.

Esempi:

```text
round_locked
prediction_submitted
match_score_changed
standings_updated
```

## 2.6 Audit Record

Registro di un'azione umana o di sistema.

---

# 3. OWNERSHIP DEGLI ENGINE

Ogni tabella deve avere un solo Engine proprietario.

## 3.1 Competition Engine

Possiede:

```text
sports
competitions
competition_editions
competition_stages
teams
competition_teams
provider_rounds
matches
fantagol_rounds
fantagol_round_matches
match_set_versions
team_aliases
```

## 3.2 League Engine

Possiede:

```text
leagues
league_members
league_modes
league_fixtures
clubs
```

## 3.3 Prediction Engine

Possiede:

```text
predictions
prediction_snapshots
```

## 3.4 Odds Engine

Possiede:

```text
odds_snapshots
aggregated_odds_snapshots
surprise_outcomes
```

## 3.5 Scoring Engine

Possiede:

```text
prediction_score_results
scoring_components
calculation_runs
```

## 3.6 Strategy Engine

Possiede:

```text
fantacalcio_allocations
one_to_one_matrices
one_to_one_matrix_entries
strategy_snapshots
```

## 3.7 Mode Engine

Possiede:

```text
mode_results
league_fixture_results
round_user_scores
```

## 3.8 Standings Engine

Possiede:

```text
standings
standing_snapshots
```

## 3.9 Live Engine

Possiede:

```text
match_events
live_snapshots
provider_sync_runs
```

## 3.10 Control Room Engine

Possiede:

```text
control_room_aggregates
control_room_access_sessions
historical_analytics
```

## 3.11 Monetisation Engine

Possiede:

```text
pass_wallets
pass_transactions
pass_gifts
purchase_records
rewarded_ad_records
```

---

# 4. NAMING STANDARD

## 4.1 Tabelle

Usare:

```text
snake_case
plural nouns
```

Esempi:

```text
competition_editions
fantagol_round_matches
prediction_score_results
```

## 4.2 Colonne

Usare nomi espliciti.

Preferire:

```text
competition_id
fantagol_round_id
predicted_home_score
```

Evitare:

```text
comp
round
score
data
value
```

## 4.3 Primary Key

Nome standard:

```text
id
```

Tipo:

```text
uuid
```

## 4.4 Foreign Key

Formato:

```text
<entity>_id
```

## 4.5 Constraint

Formato:

```text
<table>_<meaning>_<type>
```

Esempi:

```text
fantagol_rounds_dates_check
matches_teams_different_check
predictions_user_match_unique
```

## 4.6 Index

Formato:

```text
<table>_<columns_or_purpose>_idx
```

## 4.7 RPC

Formato:

```text
verb_noun_rpc
```

Esempi:

```text
create_fantagol_round_rpc
save_prediction_rpc
lock_round_rpc
```

## 4.8 View

Formato:

```text
<purpose>_view
```

---

# 5. UUID POLICY

## 5.1 Default

```sql
gen_random_uuid()
```

## 5.2 Regola

Gli UUID interni non derivano da:

- provider ID;
- email;
- nome;
- slug;
- codice invito.

## 5.3 External ID

Sempre in tabella mapping.

## 5.4 Deterministic UUID

Ammesso solo per seed o mapping controllati, mai come default generale.

---

# 6. TIMESTAMP POLICY

## 6.1 Tipo

Sempre:

```text
timestamptz
```

## 6.2 Storage

UTC.

## 6.3 Colonne standard

```text
created_at
updated_at
deleted_at nullable
locked_at nullable
official_at nullable
finalised_at nullable
```

## 6.4 Date pure

Usare `date` solo per concetti senza ora reale:

```text
launch_date
birth_date
```

---

# 7. VERSIONING POLICY

## 7.1 Row Version

Entità critiche:

```text
version integer not null default 1
```

## 7.2 Ruleset Version

Ogni calcolo ufficiale conserva:

```text
scoring_version
strategy_version
mode_ruleset_version
odds_policy_version
```

## 7.3 Snapshot Version

Gli snapshot sono immutabili.

Nuova modifica = nuova versione.

## 7.4 Migration Version

Ogni migration ha ID univoco e ordinato.

---

# 8. SOFT DELETE E ARCHIVIAZIONE

## 8.1 Preferenza

Per entità con valore storico usare:

```text
status
active
archived_at
deleted_at
```

## 8.2 Hard Delete

Consentito solo per:

- dati temporanei;
- righe non referenziate;
- dati di test;
- rollback controllato;
- compliance legale.

## 8.3 Audit

Le cancellazioni amministrative devono essere tracciate.

---

# 9. FOREIGN KEY POLICY

## 9.1 RESTRICT

Usare quando l'entità non deve essere cancellata se referenziata.

Esempi:

```text
matches → teams
competition_editions → competitions
```

## 9.2 CASCADE

Usare solo per child strettamente dipendenti.

Esempi:

```text
competition_stages → competition_editions
fantagol_round_matches → fantagol_rounds
```

## 9.3 SET NULL

Usare per riferimenti opzionali o storici.

Esempi:

```text
stage_id
created_by
provider_round_id
```

## 9.4 Auth Users

Valutare con cautela:

```text
ON DELETE CASCADE
ON DELETE SET NULL
```

Storico competitivo ed economico non deve sparire automaticamente.

---

# 10. UNIQUE POLICY

Ogni business key deve essere protetta.

Esempi:

```text
competitions(code)
competition_editions(competition_id, label)
competition_stages(edition_id, code)
league_members(league_id, user_id)
predictions(league_id, user_id, match_id)
fantagol_round_matches(fantagol_round_id, slot_number)
```

Le unique devono essere accompagnate da nomi espliciti.

---

# 11. CHECK CONSTRAINT POLICY

## 11.1 Valori ammessi

Preferire `text + check` nella fase iniziale.

## 11.2 Range

Esempi:

```text
score >= 0
position > 0
minute between 0 and 150
priority >= 0
```

## 11.3 Coerenza temporale

Esempi:

```text
opens_at < lock_at
lock_at <= starts_at
starts_at <= ends_at
```

## 11.4 Coerenza logica

Esempi:

```text
home_team_id <> away_team_id
minimum_match_count <= target_match_count
target_match_count <= maximum_match_count
```

---

# 12. ENUM POLICY

## 12.1 Default

Preferire:

```text
text + check constraint
```

## 12.2 PostgreSQL ENUM

Usare solo quando:

- il dominio è stabile;
- il costo di migrazione è accettabile;
- il valore è veramente definitivo.

## 12.3 Traduzioni

I valori tecnici non vengono tradotti nel database.

---

# 13. JSONB POLICY

## 13.1 Consentito

Per:

- configurazioni;
- metadata provider;
- statistiche variabili;
- payload audit;
- compatibilità futura.

## 13.2 Vietato come sostituto di schema

Non usare JSONB per:

- FK;
- business key;
- stato principale;
- score ufficiali;
- campi ricercati frequentemente.

## 13.3 Versione

Ogni struttura JSONB rilevante deve avere schema logico documentato.

---

# 14. PROVIDER POLICY

## 14.1 Registry

I provider vivono in:

```text
data_providers
```

## 14.2 Mapping

```text
provider_entity_maps
```

## 14.3 Nessun provider hardcoded

Mai colonne come:

```text
api_football_id
football_data_id
```

## 14.4 Priorità

Configurata via dati.

## 14.5 Payload grezzo

Può essere archiviato solo quando utile per audit/debug.

---

# 15. INTERNATIONALIZATION POLICY

## 15.1 Testi UI

Non hardcoded nel database.

Usare:

```text
name_key
translation_key
locale
```

## 15.2 Nomi propri

Team e Competition possono avere nome canonico più alias localizzati.

## 15.3 Locale

Formato raccomandato:

```text
it-IT
en-GB
es-ES
de-DE
fr-FR
```

## 15.4 Timezone

Salvare timezone IANA.

Esempio:

```text
Europe/Rome
America/Mexico_City
```

---

# 16. RLS POLICY

## 16.1 Obbligo

Tutte le tabelle `public` devono avere RLS attiva.

## 16.2 Default deny

Nessuna policy = nessun accesso client.

## 16.3 Letture pubbliche

Consentite solo per dati realmente pubblici:

- competizioni;
- team;
- calendario;
- risultati reali;
- round pubblici.

## 16.4 Dati privati

Prima del lock:

- pronostici;
- strategie;
- matrici;
- dati economici;
- audit.

## 16.5 Write Client

Le scritture critiche passano da RPC o backend trusted.

## 16.6 Policy naming

Formato:

```text
<Role/Subject> can <action> <object>
```

## 16.7 Policy idempotenti

Prima di creare una policy:

```sql
drop policy if exists ...
```

---

# 17. RPC POLICY

## 17.1 SECURITY DEFINER

Usare solo quando necessario.

## 17.2 Search Path

Obbligatorio:

```sql
set search_path = public
```

## 17.3 Auth

Verifica esplicita:

```text
auth.uid() is not null
```

## 17.4 Grant

Ogni RPC deve:

```text
revoke all from public
grant execute to ruolo specifico
```

## 17.5 Error Codes

Gli errori devono avere codici stabili.

## 17.6 Idempotency

Le RPC critiche devono accettare o derivare idempotency key.

## 17.7 Audit

Le operazioni amministrative producono audit.

---

# 18. TRIGGER POLICY

## 18.1 Uso consentito

Per:

- updated_at;
- row version;
- audit tecnico;
- immutabilità;
- invariant enforcement.

## 18.2 Uso sconsigliato

Per workflow complessi o logica di business distribuita.

## 18.3 Naming

```text
set_<table>_updated_at
increment_<table>_version
protect_<entity>_after_lock
```

---

# 19. EVENT POLICY

## 19.1 Domain Event

Ogni effetto significativo produce evento.

## 19.2 Outbox

Domain write ed evento nella stessa transazione.

## 19.3 Event Envelope

```text
id
event_type
aggregate_type
aggregate_id
payload_json
event_version
producer
correlation_id
causation_id
occurred_at
processing_status
```

## 19.4 Eventi immutabili

Gli eventi non si aggiornano, salvo stato di processing.

---

# 20. AUDIT POLICY

## 20.1 Audit amministrativo

Campi minimi:

```text
actor_id
action
aggregate_type
aggregate_id
before_json
after_json
reason
correlation_id
created_at
```

## 20.2 Audit economico

Le transazioni Pass sono append-only.

## 20.3 Audit calcolo

Ogni ricalcolo conserva input version e output version.

---

# 21. READ MODEL POLICY

## 21.1 Write Model

Normalizzato e vincolato.

## 21.2 Read Model

Ottimizzato per UI.

## 21.3 View

Usare view per aggregazioni stabili.

## 21.4 Materialized View

Solo quando necessario per performance.

## 21.5 Cache

La cache non sostituisce il database autorevole.

---

# 22. INDEX POLICY

## 22.1 FK

Indicizzare tutte le FK usate frequentemente.

## 22.2 Query operative

Indicizzare:

- status;
- kickoff;
- edition;
- round;
- league;
- user;
- provider external ID.

## 22.3 Unique Index

Usare partial unique quando necessario.

## 22.4 Evitare over-indexing

Ogni indice deve avere una query giustificativa.

---

# 23. MIGRATION POLICY

## 23.1 Formato

Ogni migration contiene:

```text
header
preflight assumptions
begin
schema changes
data backfill
constraints
indexes
functions
triggers
RLS
grants
verification comments
commit
```

## 23.2 Naming

```text
NNN_feature_name.sql
NNN_feature_name_rollback.sql
```

## 23.3 Idempotenza

Usare:

```text
if not exists
drop ... if exists
on conflict do nothing
```

quando coerente.

## 23.4 Produzione

Ogni migration richiede:

1. preflight;
2. backup/snapshot;
3. review;
4. esecuzione controllata;
5. verification query;
6. build web;
7. smoke test.

## 23.5 No blind migration

Mai eseguire una migration non confrontata con lo schema reale.

## 23.6 Rollback

Ogni migration strutturale ha rollback.

## 23.7 One-way migration

Se il rollback è impossibile, deve essere dichiarato esplicitamente.

---

# 24. LEGACY POLICY

## 24.1 Convivenza

Il nuovo schema può convivere con tabelle legacy.

## 24.2 Bridge

Usare colonne nullable e mapping.

## 24.3 Cutover

Solo dopo:

- data migration;
- doppia lettura;
- confronto;
- test;
- rollback plan.

## 24.4 Deprecation

Ogni oggetto legacy deve avere:

```text
status
replacement
cutover criteria
removal migration
```

---

# 25. SEED POLICY

## 25.1 Seed minimo

Solo dati fondativi.

Esempi:

```text
football
Serie A
competition edition
regular season
provider placeholder
```

## 25.2 Calendario

Non hardcodare nella migration foundation.

## 25.3 Idempotenza

Seed con `on conflict`.

## 25.4 Ambiente

Distinguere:

```text
production seed
development seed
test fixtures
```

---

# 26. SECURITY POLICY

## 26.1 Service Role

Mai esposta al client.

## 26.2 Secrets

Mai salvati nel database pubblico.

## 26.3 Least Privilege

Grant minimo necessario.

## 26.4 Sensitive Tables

Nessun accesso anon/auth diretto a:

- provider mappings;
- audit;
- Pass;
- purchase;
- command/event store;
- admin logs.

---

# 27. PERFORMANCE POLICY

## 27.1 Prima correttezza

L'integrità viene prima della denormalizzazione.

## 27.2 Query Plan

Analizzare le query critiche.

## 27.3 Scale Targets

La foundation deve supportare:

```text
più competizioni
più lingue
migliaia di leghe
milioni di predictions
live update
aggregazioni Control Room
```

## 27.4 Partitioning

Valutare solo quando necessario.

---

# 28. OBJECTS IMMUTABILI

Questi oggetti, una volta ufficializzati, non si modificano direttamente:

```text
prediction_snapshots
match_set_versions
standing_snapshots
official prediction_score_results
pass_transactions
domain_events
calculation_runs completed
```

Ogni correzione produce una nuova versione o una transazione compensativa.

---

# 29. CANONICAL ENTITIES

Le entità canoniche della piattaforma sono:

```text
sports
competitions
competition_editions
competition_stages
teams
competition_teams
matches
provider_rounds
fantagol_rounds
fantagol_round_matches
profiles
clubs
leagues
league_members
league_modes
predictions
prediction_snapshots
league_fixtures
fantacalcio_allocations
one_to_one_matrices
one_to_one_matrix_entries
prediction_score_results
mode_results
standings
standing_snapshots
domain_events
command_logs
competition_audit_log
pass_wallets
pass_transactions
control_room_access_sessions
```

---

# 30. OBJECTS DA DEPRECARE

Nel passaggio al nuovo modello:

```text
seasons
matchdays
provider_name su matches
provider_match_id su matches
```

non vengono rimossi subito.

Stato:

```text
legacy_supported
```

Sostituzioni:

```text
seasons → competition_editions
matchdays → provider_rounds + fantagol_rounds
provider_name/provider_match_id → provider_entity_maps
```

---

# 31. FOUNDATION MIGRATION SCOPE

La prima Foundation Migration deve introdurre:

```text
sports
competitions
competition_editions
competition_stages
competition_teams
data_providers
provider_entity_maps
provider_rounds
fantagol_rounds
fantagol_round_matches
match_set_versions
team_aliases
competition_audit_log
```

e deve estendere:

```text
teams
matches
```

senza rimuovere il legacy.

La Strategy Core verrà applicata solo dopo che le strategie saranno collegate a `fantagol_rounds`.

---

# 32. FOUNDATION MIGRATION NON DEVE ANCORA CREARE

```text
prediction_snapshots
scoring engine tables
standings engine tables
control room tables
pass tables
domain event outbox completa
```

Queste appartengono a migration successive.

---

# 33. FOUNDATION ACCEPTANCE CRITERIA

La Foundation Migration è accettata quando:

1. non rompe il sito esistente;
2. non cancella dati;
3. introduce Competition Edition;
4. introduce FantaGol Round;
5. separa Provider Round e FantaGol Round;
6. mantiene `seasons` e `matchdays`;
7. mantiene `matches` compatibile;
8. mantiene `predictions` compatibile;
9. consente Serie A 2026/27;
10. consente future competizioni senza schema change;
11. tutte le nuove tabelle hanno RLS;
12. tutti i grant sono espliciti;
13. rollback disponibile;
14. build web verde;
15. smoke test login/lega/club superato.

---

# 34. ORDINE DELLE FUTURE MIGRATION

```text
001_foundation_competition_core
002_prediction_engine
003_odds_engine
004_scoring_engine
005_strategy_engine
006_mode_engine
007_standings_engine
008_live_engine
009_core_events
010_control_room
011_monetisation
012_notifications
```

L'ordine può evolvere, ma la responsabilità degli Engine non cambia.

---

# 35. DIRETTIVA FINALE

Il database FantaGol deve evolvere per estensione controllata, non per improvvisazione.

Ogni migration deve:

- rispettare il dominio;
- proteggere il legacy;
- essere provider-agnostic;
- essere international-ready;
- essere idempotente quando possibile;
- avere rollback;
- avere RLS;
- avere audit;
- avere verifica post-esecuzione.

Il database è il cuore autorevole della piattaforma e deve restare coerente anche quando web, Android, iOS, provider o infrastruttura cambiano.
