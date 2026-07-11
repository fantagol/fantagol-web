# FANTAGOL CORE ENGINE MASTER v1

**Stato:** documento fondativo  
**Ambito:** orchestrazione centrale dei motori FantaGol  
**Obiettivo:** definire come i moduli del sistema comunicano, reagiscono agli eventi, mantengono coerenza, sicurezza, tracciabilità e indipendenza tecnologica.

---

# 0. PRINCIPI FONDATIVI

## 0.1 Il Core Engine è il coordinatore

Il Core Engine non sostituisce i motori specializzati.

Coordina:

- Competition Engine;
- Provider Engine;
- Prediction Engine;
- Odds Engine;
- Scoring Engine;
- Strategy Engine;
- Mode Engine;
- Standings Engine;
- Live Engine;
- Control Room Engine;
- Notification Engine;
- Monetisation Engine.

Ogni motore mantiene una responsabilità limitata e chiara.

## 0.2 Nessun motore modifica direttamente il dominio di un altro

Esempi vietati:

```text
Live Engine → aggiorna direttamente Standing
Prediction Engine → modifica direttamente Mode Result
Competition Engine → ricalcola direttamente Score Result
Control Room Engine → scrive direttamente Prediction
```

Comunicazione corretta:

```text
Engine
  ↓
Domain Event
  ↓
Core Engine
  ↓
Command / Event Routing
  ↓
Target Engine
```

## 0.3 Event-driven, ma non necessariamente distribuito

La logica è a eventi.

L'implementazione iniziale può essere semplice:

- PostgreSQL;
- RPC;
- Edge Functions;
- cron;
- tabelle eventi;
- code interne leggere.

Non è obbligatorio usare subito Kafka, RabbitMQ o sistemi complessi.

L'architettura deve però essere compatibile con una futura evoluzione distribuita.

## 0.4 Determinismo

Ogni risultato ufficiale deve essere riproducibile.

Stessi input:

- Prediction Snapshot;
- Match Result;
- Odds Snapshot;
- Strategy Snapshot;
- Ruleset Version;

devono produrre lo stesso output.

## 0.5 Idempotenza

Ogni comando ed evento deve poter essere ritentato senza duplicare effetti.

## 0.6 Separazione tra dominio e infrastruttura

Il dominio non deve dipendere da:

- Supabase;
- Vercel;
- Next.js;
- Android;
- provider esterno;
- singola lingua;
- singola competizione.

---

# 1. POSIZIONE DEL CORE ENGINE

```text
                    CLIENTS
      ┌──────────────┼──────────────┐
      │              │              │
     WEB          ANDROID          iOS
      │              │              │
      └──────────────┼──────────────┘
                     │
                  API LAYER
                     │
                CORE ENGINE
                     │
 ┌────────────┬────────────┬────────────┬────────────┐
 │            │            │            │            │
Competition Prediction   Scoring      Strategy      Live
Engine      Engine       Engine       Engine        Engine
 │            │            │            │            │
 └────────────┴────────────┴────────────┴────────────┘
                     │
               DATA / EVENT STORE
```

---

# 2. RESPONSABILITÀ DEL CORE ENGINE

## 2.1 Command Routing

Riceve comandi e li inoltra al motore competente.

Esempi:

```text
CreateFantaGolRound
OpenPredictions
SubmitPrediction
SubmitFantacalcioStrategy
SubmitOneToOneMatrix
LockRound
CalculateProvisionalScores
FinaliseRound
RecalculateRound
GrantPass
StartControlRoomSession
```

## 2.2 Event Routing

Riceve eventi e determina quali motori devono reagire.

Esempio:

```text
MatchFinished
  ↓
Scoring Engine
  ↓
PredictionScoreCalculated
  ↓
Mode Engine
  ↓
ModeResultCalculated
  ↓
Standings Engine
  ↓
StandingsUpdated
  ↓
Notification Engine
  ↓
Control Room Engine
```

## 2.3 Workflow Orchestration

Coordina processi composti da più passaggi.

Esempio ufficializzazione round:

```text
ValidateRoundCompleteness
→ FreezeSourceDataVersion
→ CalculateOfficialPredictionScores
→ CalculateModeResults
→ UpdateStandings
→ CreateStandingSnapshot
→ PublishRoundFinalised
→ TriggerNotifications
→ RefreshControlRoomAggregates
```

## 2.4 Transaction Boundary

Definisce quali operazioni devono essere atomiche.

Esempi:

- invio strategia completa;
- lock round;
- calcolo ufficiale;
- assegnazione Pass;
- regalo Pass;
- aggiornamento classifica.

## 2.5 Error Handling

Classifica errori in:

```text
validation_error
authorization_error
conflict_error
dependency_error
provider_error
calculation_error
infrastructure_error
```

## 2.6 Audit

Registra:

- comando ricevuto;
- utente o sistema origine;
- evento prodotto;
- versione regole;
- risultato;
- errore;
- durata;
- timestamp.

---

# 3. MODELLI DI COMUNICAZIONE

## 3.1 Command

Un Command richiede un'azione.

Formato logico:

```text
command_id
command_type
aggregate_type
aggregate_id
actor_id
payload
requested_at
correlation_id
causation_id
idempotency_key
```

Esempi:

```text
SubmitPrediction
LockRound
CalculateFinalScores
GrantRewardPass
```

## 3.2 Domain Event

Un Domain Event descrive un fatto già avvenuto.

Formato logico:

```text
event_id
event_type
aggregate_type
aggregate_id
payload
occurred_at
correlation_id
causation_id
event_version
producer
```

Esempi:

```text
PredictionSubmitted
RoundLocked
MatchScoreChanged
PredictionScoreCalculated
StandingsUpdated
PassRewarded
```

## 3.3 Query

Una Query legge dati senza modificare lo stato.

Esempi:

```text
GetCurrentRound
GetMyPredictions
GetLiveRoundState
GetLeagueStandings
GetControlRoomOverview
```

## 3.4 Correlation ID

Collega tutti i passaggi di uno stesso workflow.

Esempio:

```text
finalise_round correlation_id = XYZ
```

Tutti gli eventi generati da quel processo mantengono lo stesso ID.

## 3.5 Causation ID

Indica quale comando o evento ha generato il successivo.

---

# 4. ENGINE REGISTRY

## 4.1 Competition Engine

**Responsabilità:**

- Competition;
- Edition;
- Stage;
- Team;
- Match;
- Provider Round;
- FantaGol Round;
- Match Set;
- lifecycle temporale del round.

**Emette:**

```text
CompetitionCreated
EditionCreated
StageCreated
MatchImported
MatchUpdated
FantaGolRoundCreated
MatchSetApproved
RoundOpened
RoundLocked
RoundCancelled
```

**Consuma:**

```text
ProviderCompetitionSynced
ProviderCalendarSynced
AdminRoundApproved
ClockReachedOpenAt
ClockReachedLockAt
```

## 4.2 Provider Engine

**Responsabilità:**

- adapter;
- mapping ID;
- sincronizzazione;
- fallback;
- qualità dati;
- rate limit.

**Emette:**

```text
ProviderSyncStarted
ProviderSyncCompleted
ProviderSyncFailed
ProviderEntityMapped
ProviderDataConflictDetected
```

## 4.3 Prediction Engine

**Responsabilità:**

- draft;
- submit;
- edit;
- lock;
- snapshot;
- missing prediction policy.

**Emette:**

```text
PredictionDraftSaved
PredictionSubmitted
PredictionUpdated
PredictionLocked
PredictionSnapshotCreated
PredictionMissingRecorded
```

**Consuma:**

```text
RoundOpened
RoundLocked
```

## 4.4 Odds Engine

**Responsabilità:**

- raccolta quote;
- normalizzazione;
- aggregazione;
- validazione qualità;
- Surprise Outcome.

**Emette:**

```text
OddsSnapshotCollected
AggregatedOddsSnapshotCreated
SurpriseOutcomeCalculated
OddsQualityInsufficient
```

## 4.5 Scoring Engine

**Responsabilità:**

- Exact;
- Segno;
- Over/Under;
- Goal/No Goal;
- Bonus;
- Malus;
- Prediction Score Result.

**Emette:**

```text
ProvisionalPredictionScoreCalculated
OfficialPredictionScoreCalculated
PredictionScoreRecalculated
ScoringFailed
```

**Consuma:**

```text
MatchScoreChanged
MatchFinished
RoundFinalCalculationRequested
RoundRecalculationRequested
```

## 4.6 Strategy Engine

**Responsabilità:**

- Attack/Defense;
- One To One Matrix;
- validazioni;
- strategic modifiers;
- strategy snapshot.

**Emette:**

```text
FantacalcioStrategySubmitted
FantacalcioStrategyLocked
OneToOneMatrixSubmitted
OneToOneMatrixLocked
StrategicScoreCalculated
MiniChallengeCalculated
```

## 4.7 Mode Engine

**Responsabilità:**

- Punti Puri;
- Fantacalcio;
- One To One;
- Mode Result;
- League Fixture Result.

**Emette:**

```text
PointsPureResultCalculated
FantacalcioResultCalculated
OneToOneResultCalculated
LeagueFixtureResultCalculated
```

## 4.8 Standings Engine

**Responsabilità:**

- standings;
- tiebreaker;
- snapshots;
- provisional vs official.

**Emette:**

```text
ProvisionalStandingsUpdated
OfficialStandingsUpdated
StandingSnapshotCreated
```

## 4.9 Live Engine

**Responsabilità:**

- polling;
- normalizzazione live;
- cambio stato;
- cambio punteggio;
- live snapshot;
- realtime delivery.

**Emette:**

```text
MatchStarted
MatchScoreChanged
MatchStatusChanged
MatchFinished
LiveSnapshotUpdated
```

## 4.10 Control Room Engine

**Responsabilità:**

- statistiche aggregate;
- trend;
- storico;
- accessi;
- scope.

**Emette:**

```text
ControlRoomAggregateUpdated
ControlRoomSessionStarted
ControlRoomSessionExpired
```

## 4.11 Notification Engine

**Responsabilità:**

- notifiche in-app;
- email;
- push;
- preferenze;
- deduplicazione.

**Emette:**

```text
NotificationQueued
NotificationSent
NotificationFailed
```

## 4.12 Monetisation Engine

**Responsabilità:**

- Pass Wallet;
- Pass Transaction;
- acquisti;
- reward;
- gift;
- refund;
- ads.

**Emette:**

```text
PassPurchased
PassRewarded
PassGifted
PassConsumed
PassRefunded
```

---

# 5. WORKFLOW PRINCIPALI

## 5.1 Creazione FantaGol Round

```text
CreateFantaGolRound
→ Competition Engine
→ validate edition/stage
→ create round
→ select matches
→ validate match set
→ MatchSetApproved
→ schedule open/lock
→ FantaGolRoundCreated
```

## 5.2 Apertura Pronostici

```text
ClockReachedOpenAt
→ Core Engine
→ Competition Engine
→ RoundOpened
→ Prediction Engine
→ enable drafts
→ Notification Engine
→ notify users
```

## 5.3 Invio Pronostico

```text
SubmitPrediction
→ authorization
→ round state validation
→ Prediction Engine
→ upsert prediction
→ PredictionSubmitted
→ audit
```

## 5.4 Invio Strategia Fantacalcio

```text
SubmitFantacalcioStrategy
→ validate 10 predictions
→ validate 5 Attack
→ validate 5 Defense
→ validate uniqueness
→ save strategy
→ FantacalcioStrategySubmitted
```

## 5.5 Invio Matrice One To One

```text
SubmitOneToOneMatrix
→ validate fixture
→ validate ownership
→ validate 10 own predictions
→ validate 10 opponent predictions
→ validate uniqueness
→ save matrix
→ OneToOneMatrixSubmitted
```

## 5.6 Lock del Round

```text
ClockReachedLockAt
→ LockRound
→ Competition Engine
→ set round locked
→ Prediction Engine
→ create immutable snapshots
→ Strategy Engine
→ lock strategies
→ Odds Engine
→ freeze official odds snapshot
→ RoundLocked
→ Notification Engine
```

## 5.7 Aggiornamento Live

```text
Provider Poll
→ Provider Engine
→ Live Engine
→ compare previous state
→ if meaningful change:
    MatchScoreChanged / MatchStatusChanged
→ Scoring Engine
→ provisional scores
→ Mode Engine
→ provisional mode results
→ Standings Engine
→ provisional standings
→ realtime delivery
```

## 5.8 Ufficializzazione Round

```text
FinaliseRound
→ validate all required matches
→ freeze source data version
→ Scoring Engine official calculation
→ Strategy Engine strategic calculation
→ Mode Engine official results
→ Standings Engine official update
→ StandingSnapshotCreated
→ RoundFinalised
→ Control Room aggregate refresh
→ Notification Engine
```

## 5.9 Ricalcolo

```text
RecalculateRound
→ validate actor permission
→ require reason
→ freeze selected input versions
→ new Calculation Run
→ recompute
→ compare previous output
→ persist delta
→ audit
→ RoundRecalculated
```

## 5.10 Consumo Pass

```text
StartControlRoomSession
→ Monetisation Engine
→ verify wallet balance
→ consume Pass atomically
→ create access session
→ PassConsumed
→ ControlRoomSessionStarted
```

---

# 6. EVENT STORE

## 6.1 Obiettivo

Conservare eventi significativi per:

- audit;
- debug;
- ricalcolo;
- integrazioni future;
- analytics;
- recovery.

## 6.2 Struttura minima

```text
domain_event
- id
- event_type
- aggregate_type
- aggregate_id
- payload_json
- event_version
- producer
- correlation_id
- causation_id
- occurred_at
- processed_at nullable
- processing_status
```

## 6.3 Stati processing

```text
pending
processing
processed
failed
dead_letter
```

## 6.4 Outbox Pattern

Le modifiche al dominio e la registrazione dell'evento devono avvenire nella stessa transazione.

```text
domain write
+
outbox event
=
single transaction
```

## 6.5 Dead Letter

Gli eventi falliti dopo più tentativi devono essere spostati in una coda di errore ispezionabile.

---

# 7. COMMAND STORE

## 7.1 Struttura minima

```text
command_log
- id
- command_type
- aggregate_type
- aggregate_id
- actor_id
- payload_json
- idempotency_key
- correlation_id
- status
- requested_at
- completed_at nullable
- error_code nullable
- error_message nullable
```

## 7.2 Stati

```text
received
validated
processing
completed
rejected
failed
```

---

# 8. IDEMPOTENZA

## 8.1 Obbligo

Comandi critici richiedono `idempotency_key`.

Esempi:

```text
SubmitPrediction
LockRound
FinaliseRound
GrantPass
ConsumePass
RecalculateRound
```

## 8.2 Regola

Stessa `idempotency_key` + stesso attore + stesso command type:

- non produce un nuovo effetto;
- restituisce il risultato già esistente.

## 8.3 Provider Event Deduplication

Usare una chiave derivata da:

```text
provider
external_entity_id
event_type
provider_updated_at
payload_hash
```

---

# 9. CONCORRENZA

## 9.1 Optimistic Locking

Entità critiche devono avere:

```text
version
updated_at
```

## 9.2 Conflitti da gestire

- doppio submit;
- submit durante lock;
- aggiornamento live simultaneo;
- finalizzazione concorrente;
- consumo doppio Pass;
- ricalcolo sovrapposto.

## 9.3 Advisory Lock / Row Lock

Operazioni critiche possono usare:

- `SELECT ... FOR UPDATE`;
- PostgreSQL advisory lock;
- unique constraint;
- transaction isolation.

---

# 10. TRANSAZIONI

## 10.1 Operazioni atomiche

Devono essere atomiche:

- creazione lega + owner membership;
- submit strategia completa;
- lock round;
- official calculation write;
- standings update;
- Pass consume;
- Pass gift;
- purchase settlement.

## 10.2 Operazioni eventualmente consistenti

Possono essere asincrone:

- notifiche;
- Control Room aggregates;
- analytics;
- email;
- push;
- cache refresh.

---

# 11. SICUREZZA

## 11.1 Trust Boundary

Client non fidati:

- web;
- Android;
- iOS;
- browser API calls.

Trusted server:

- server actions;
- edge functions;
- cron;
- service role;
- database functions controllate.

## 11.2 Authorization

Ogni comando deve verificare:

- autenticazione;
- membership;
- ruolo;
- ownership;
- stato round;
- finestra temporale;
- regola di dominio.

## 11.3 RPC

Le RPC `SECURITY DEFINER` devono:

- impostare `search_path`;
- validare `auth.uid()`;
- limitare grant;
- evitare SQL dinamico non necessario;
- restituire errori controllati;
- essere versionate quando cambia il contratto.

## 11.4 Data Privacy

Prima del lock:

- pronostici privati;
- strategie private;
- matrici private.

Dopo il lock:

- visibilità secondo ruleset e policy lega.

---

# 12. VERSIONAMENTO

## 12.1 Event Version

Ogni evento ha una versione.

```text
PredictionSubmitted.v1
PredictionSubmitted.v2
```

## 12.2 Command Version

I contratti dei comandi possono essere versionati.

## 12.3 Ruleset Version

Ogni calcolo deve memorizzare:

```text
scoring_version
strategy_version
mode_ruleset_version
odds_policy_version
```

## 12.4 Schema Evolution

Nuove versioni devono essere retrocompatibili quando possibile.

---

# 13. ERROR MODEL

## 13.1 Struttura

```text
error_code
error_category
message_key
details
retryable
correlation_id
```

## 13.2 Esempi

```text
ROUND_ALREADY_LOCKED
PREDICTION_WINDOW_CLOSED
INVALID_ATTACK_DEFENSE_SPLIT
INVALID_ONE_TO_ONE_MATRIX
INSUFFICIENT_PASS_BALANCE
PROVIDER_RATE_LIMITED
ROUND_NOT_FINALISABLE
```

## 13.3 UI Translation

Il backend restituisce `message_key`.

La UI traduce.

---

# 14. OBSERVABILITY

## 14.1 Metriche minime

```text
commands_received_total
commands_failed_total
events_published_total
events_failed_total
provider_sync_duration
scoring_duration
round_finalisation_duration
live_update_latency
notification_failure_rate
pass_transaction_failure_rate
```

## 14.2 Log strutturati

Campi minimi:

```text
timestamp
level
service
engine
command_type
event_type
aggregate_id
correlation_id
user_id nullable
error_code nullable
```

## 14.3 Health Check

Ogni engine deve esporre uno stato:

```text
healthy
degraded
unavailable
```

---

# 15. SCHEDULER

## 15.1 Tipi di job

```text
open_round
lock_round
poll_live_matches
refresh_odds
finalise_round_candidate
retry_failed_events
expire_control_room_sessions
send_notifications
```

## 15.2 Regola

Lo scheduler emette comandi.

Non modifica direttamente le tabelle di dominio.

Esempio corretto:

```text
cron
→ LockRound command
→ Core Engine
→ Competition Engine
```

---

# 16. API LAYER

## 16.1 Responsabilità

L'API Layer:

- autentica;
- valida forma minima;
- genera command/query;
- invoca Core Engine;
- traduce errori;
- restituisce DTO.

Non contiene logica di gioco.

## 16.2 Command Endpoint

Esempi:

```text
POST /api/commands/submit-prediction
POST /api/commands/submit-fantacalcio-strategy
POST /api/commands/submit-one-to-one-matrix
POST /api/commands/finalise-round
```

## 16.3 Query Endpoint

Esempi:

```text
GET /api/queries/current-round
GET /api/queries/my-predictions
GET /api/queries/live-round
GET /api/queries/standings
```

---

# 17. READ MODEL

## 17.1 Principio CQRS leggero

Scrittura e lettura possono avere modelli diversi.

Write model:

- normalizzato;
- vincolato;
- transazionale.

Read model:

- ottimizzato per UI;
- denormalizzato;
- aggiornato da eventi;
- cacheable.

## 17.2 Read Model iniziali

```text
league_dashboard_view
current_round_view
my_predictions_view
live_round_view
fantacalcio_duel_view
one_to_one_duel_view
points_pure_standing_view
control_room_overview_view
```

---

# 18. CACHE

## 18.1 Cacheable

- competizioni;
- team;
- calendario;
- round pubblici;
- classifiche ufficiali;
- statistiche aggregate.

## 18.2 Non cacheare senza cautela

- pronostici privati;
- strategie private;
- Pass Wallet;
- stato lock;
- comandi critici.

## 18.3 Invalidation

Preferire invalidazione a eventi.

Esempio:

```text
OfficialStandingsUpdated
→ invalidate standings cache
```

---

# 19. DEPLOYMENT EVOLUTION

## 19.1 Fase iniziale

```text
Next.js
Supabase
PostgreSQL
Supabase RPC
Edge Functions
Cron
Realtime
```

## 19.2 Fase crescita

Possibili evoluzioni:

```text
dedicated workers
queue service
separate scoring service
separate live ingestion service
event streaming platform
data warehouse
```

Il dominio resta invariato.

---

# 20. ENGINE CONTRACT

Ogni Engine deve dichiarare:

```text
name
responsibility
owned_entities
accepted_commands
emitted_events
consumed_events
queries
transaction_boundaries
authorization_rules
idempotency_rules
error_codes
metrics
```

---

# 21. INVARIANTI DEL CORE ENGINE

1. Nessun Engine scrive direttamente nel dominio di un altro Engine.
2. Ogni effetto significativo produce un Domain Event.
3. Ogni workflow critico usa Correlation ID.
4. Ogni comando critico è idempotente.
5. Ogni calcolo ufficiale è versionato.
6. Gli eventi sono persistiti con Outbox Pattern.
7. Le notifiche non bloccano il calcolo ufficiale.
8. La Control Room non modifica il gioco.
9. Il client non contiene logica autorevole.
10. Lo scheduler emette comandi, non scrive direttamente.
11. Le letture non devono modificare stato.
12. I provider non definiscono il dominio.
13. Gli errori usano codici stabili e traducibili.
14. Le operazioni economiche sono atomiche.
15. Gli Engine devono essere sostituibili senza cambiare il dominio.

---

# 22. IMPLEMENTAZIONE INCREMENTALE

## Phase 1 — Core Contracts

- Command envelope;
- Event envelope;
- Error model;
- Correlation ID;
- Idempotency key;
- Engine registry.

## Phase 2 — Event Store / Outbox

- domain_event;
- command_log;
- outbox processing;
- retry;
- dead letter.

## Phase 3 — Competition Workflow

- round creation;
- round open;
- round lock;
- provider sync events.

## Phase 4 — Prediction Workflow

- draft;
- submit;
- lock;
- snapshot.

## Phase 5 — Scoring Workflow

- provisional;
- official;
- recalculation.

## Phase 6 — Strategy / Mode / Standings

- Attack/Defense;
- matrices;
- H2H results;
- standings.

## Phase 7 — Live / Notification

- provider ingestion;
- domain changes;
- realtime;
- notifications.

## Phase 8 — Control Room / Monetisation

- Pass;
- sessions;
- aggregates;
- analytics.

---

# 23. DECISIONI INIZIALI DI IMPLEMENTAZIONE

Per il lancio Serie A in italiano:

```text
architecture_mode = modular_monolith
event_processing = database_outbox
event_transport = PostgreSQL + worker
deployment = Next.js + Supabase
write_api = RPC / server functions
read_api = views / server queries
language_active = it
competition_active = Serie A
```

Il sistema resta International Ready.

---

# 24. DIRETTIVA FINALE

Il Core Engine è il contratto centrale della piattaforma FantaGol.

Il suo scopo non è aggiungere complessità, ma impedire accoppiamenti incontrollati tra moduli.

La prima implementazione deve restare semplice, osservabile e testabile.

Ogni futura evoluzione infrastrutturale deve preservare:

- Command;
- Domain Event;
- idempotenza;
- versionamento;
- audit;
- ownership degli Engine;
- separazione tra dominio e client.
