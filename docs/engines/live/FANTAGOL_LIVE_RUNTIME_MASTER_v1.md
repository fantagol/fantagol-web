# FANTAGOL LIVE RUNTIME MASTER v1

**Stato:** documento fondativo operativo  
**Ambito:** esecuzione applicativa del Live State Engine su Web, Android e servizi backend  
**Obiettivo:** definire come FantaGol acquisisce gli aggiornamenti reali, ricostruisce gli artefatti provvisori, pubblica snapshot coerenti e mantiene sincronizzati tutti i client senza spostare la logica di dominio nel frontend.

---

# 0. AUTORITÀ E RELAZIONE CON GLI ALTRI MASTER

## 0.1 Documento complementare

Questo documento non sostituisce:

```text
FANTAGOL_LIVE_STATE_ENGINE_MASTER_v1
```

Il Live State Engine Master definisce:

- stati;
- transizioni;
- artefatti;
- semantica live;
- comportamento visivo;
- contratti di dominio.

Il Live Runtime Master definisce:

- dove viene eseguita l'orchestrazione;
- come vengono acquisiti gli aggiornamenti;
- quando viene ricostruita la Simulation Platform;
- come vengono pubblicate le nuove versioni;
- come Web e Android recuperano lo stato;
- come vengono gestiti errori, retry, cache e concorrenza.

```text
LIVE STATE ENGINE MASTER
        ↓
definisce il comportamento

LIVE RUNTIME MASTER
        ↓
definisce l'esecuzione
```

## 0.2 Fonti autorevoli

Il Runtime deve rispettare:

```text
FANTAGOL_SYSTEM_ARCHITECTURE_v1
FANTAGOL_CORE_ENGINE_MASTER_v1
FANTAGOL_GAME_ENGINE_MASTER_v1
FANTAGOL_LIVE_STATE_ENGINE_MASTER_v1
FANTAGOL_ROUND_SIMULATION_ENGINE_MASTER_v1
FANTAGOL_COMMUNITY_INTELLIGENCE_MASTER_v1
```

## 0.3 Regola di precedenza

Quando implementazione e documentazione risultano in conflitto:

```text
Domain MASTER
    prevale su
Runtime Implementation
```

---

# 1. PRINCIPI FONDATIVI

## 1.1 Il Runtime orchestra, non decide

Il Live Runtime:

- non calcola direttamente punti;
- non determina bonus o malus;
- non converte punti in gol;
- non costruisce classifiche autonomamente;
- non certifica risultati;
- non modifica pronostici o strategie;
- non contiene regole di gioco duplicate.

Il Runtime attiva i motori autorevoli nella sequenza corretta.

## 1.2 Il database resta la fonte autorevole

PostgreSQL/Supabase possiede:

- Match State normalizzato;
- Calculation Run;
- Prediction Runtime Results;
- Round Simulations;
- UI Snapshot;
- Live State Snapshot;
- Certification;
- Ledger;
- audit ed eventi.

Il Runtime applicativo è sostituibile.

La perdita o il riavvio del processo runtime non deve causare perdita dello stato ufficiale.

## 1.3 Il client non interroga i provider

Sono vietate chiamate dirette dai client a provider sportivi.

```text
Web / Android
      X
Provider esterno
```

Flusso corretto:

```text
Provider
   ↓
Backend FantaGol
   ↓
Database / Simulation
   ↓
Realtime Publication
   ↓
Web / Android
```

## 1.4 Aggiornamenti significativi, non polling rumoroso

Il Runtime deve produrre una nuova pipeline soltanto quando cambia almeno uno dei seguenti elementi:

- stato della partita;
- punteggio;
- minuto o periodo, quando utile al prodotto;
- kickoff;
- rinvio;
- annullamento;
- assegnazione a tavolino;
- stato del round;
- stato della Calculation Run;
- stato della certificazione.

Una risposta provider identica non deve generare:

- nuovi eventi;
- nuovi Calculation Run;
- nuove Round Simulation;
- nuove pubblicazioni realtime.

## 1.5 Snapshot coerenti

Ogni pubblicazione deve riferirsi a una sola versione completa.

È vietato pubblicare contemporaneamente:

- risultato della versione N;
- icone della versione N−1;
- classifica della versione N−2.

## 1.6 Recovery by snapshot

Gli eventi realtime migliorano la velocità percepita, ma non sono la fonte esclusiva.

Ogni client deve poter recuperare:

```text
latest_published_snapshot
```

e riallinearsi integralmente.

## 1.7 Una sola animazione di sistema

Il Runtime pubblica lo stato logico necessario al linguaggio visivo minimale.

### Pre-live

```text
visual_state = dormant
animation_state = none
```

### Live

```text
visual_state = live
animation_state = soft_pulse
```

La pulsazione coinvolge l'intero evento:

- squadre reali;
- risultato;
- pronostico dell'utente;
- area punteggio.

Le icone non pulsano autonomamente: cambiano stato in funzione del risultato provvisorio.

### Post-live e Certified

```text
visual_state = acquired
animation_state = none
```

L'unica eccezione pre-live è:

```text
surprise_icon = candidate
```

che accende esclusivamente il cerchio esterno del Bonus Sorpresa potenziale.

---

# 2. POSIZIONE NELL'ARCHITETTURA

```text
Football Data / Live Provider
            ↓
Provider Adapter
            ↓
Normalized Match Update
            ↓
Match State Persistence
            ↓
Prediction Resolution Engine
            ↓
Round Simulation Pipeline
            ├── Points Preview
            ├── Fantacalcio Preview
            ├── One-to-One Preview
            ├── Standings Preview
            └── UI Snapshot
            ↓
Live State Snapshot
            ↓
Realtime Publication
            ↓
Web / Android / Control Room
```

## 2.1 Confini

### Provider Layer

Responsabile di:

- chiamata esterna;
- mapping degli ID;
- normalizzazione;
- retry provider;
- rate limit;
- qualità del dato.

### Database Domain Layer

Responsabile di:

- persistenza;
- determinismo;
- versionamento;
- immutabilità;
- Calculation Run;
- Builder;
- snapshot;
- certificazione;
- ledger.

### Live Runtime

Responsabile di:

- scheduler;
- orchestrazione;
- lock applicativo;
- deduplicazione runtime;
- trigger della pipeline;
- pubblicazione;
- retry;
- health state.

### Client

Responsabile esclusivamente di:

- ricevere;
- validare la versione;
- salvare cache locale;
- renderizzare;
- richiedere recovery snapshot.

---

# 3. COMPONENTI DEL RUNTIME

## 3.1 Live Scheduler

Determina quali competizioni e round devono essere osservati.

Input:

```text
active competitions
active editions
active FantaGol rounds
match kickoff
match status
round status
provider configuration
```

Output:

```text
poll jobs
rebuild jobs
certification readiness jobs
```

## 3.2 Provider Poll Worker

Esegue la chiamata al provider live.

Responsabilità:

- timeout;
- rate limit;
- retry controllato;
- response validation;
- mapping ID;
- payload hash;
- metriche.

Non aggiorna direttamente punteggi o UI.

## 3.3 Match Update Normalizer

Converte il provider payload nel contratto interno.

Output minimo:

```text
provider
external_match_id
internal_match_id
status
home_score
away_score
minute
period
kickoff_at
provider_updated_at
source_payload_hash
received_at
```

## 3.4 Meaningful Change Detector

Confronta lo stato normalizzato con quello autorevole già persistito.

Output:

```text
NO_CHANGE
MATCH_STATE_CHANGED
MATCH_SCORE_CHANGED
MATCH_KICKOFF_CHANGED
MATCH_POSTPONED
MATCH_CANCELLED
MATCH_FINISHED
MATCH_AWARDED
```

## 3.5 Pipeline Orchestrator

Quando esiste una variazione significativa, esegue:

```text
persist normalized match state
→ resolve affected league rounds
→ build Calculation Run
→ build Points Preview
→ build Fantacalcio Preview
→ build One-to-One Preview
→ build Standings Preview
→ build UI Snapshot
→ build Live State Snapshot
→ publish latest version
```

## 3.6 Realtime Publisher

Pubblica soltanto snapshot completi e pronti.

Canali logici:

```text
competition:{competition_id}
fantagol_round:{fantagol_round_id}
league:{league_id}
league_round:{league_round_id}
member:{league_member_id}
```

Il payload pubblico può essere:

```text
snapshot_reference
```

oppure, quando efficiente:

```text
compact_snapshot_payload
```

## 3.7 Recovery API

Restituisce l'ultimo snapshot pubblicato e autorizzato.

Query canoniche:

```text
GetLatestPublishedLiveSnapshot
GetLeagueRoundLiveState
GetMyLiveRoundState
```

## 3.8 Runtime Health Monitor

Registra:

- provider availability;
- last successful poll;
- last meaningful update;
- last successful pipeline;
- last publication;
- consecutive failures;
- stale state;
- degraded mode.

---

# 4. UNITÀ DI ESECUZIONE

## 4.1 Scope primario

L'unità minima di ingestione è:

```text
Match
```

L'unità minima di rebuild è:

```text
League Round
```

Un aggiornamento di una singola partita può influenzare molte leghe.

## 4.2 Fan-out

```text
1 Match Update
      ↓
1 FantaGol Round
      ↓
N League Rounds
      ↓
N Calculation Runs
      ↓
N UI / Live Snapshots
```

## 4.3 Separazione tra dati globali e dati di lega

Lo stato reale della partita è globale.

I punteggi e le simulazioni sono specifici della lega.

```text
Match State
   shared

Prediction / Strategy / Standings
   league scoped
```

---

# 5. MACCHINA A STATI RUNTIME

## 5.1 Runtime Match State

```text
scheduled
imminent
live
halftime
post_live
postponed
cancelled
awarded
certified
```

## 5.2 Runtime Round State

```text
pre_live
partially_live
live
partially_post_live
waiting_postponed
awaiting_final_calculation
awaiting_certification
certified
```

## 5.3 Runtime Processing State

```text
idle
polling
change_detected
persisting
rebuilding
publishing
healthy
degraded
failed
paused
```

## 5.4 Transizione tipica

```text
idle
  ↓
polling
  ↓
change_detected
  ↓
persisting
  ↓
rebuilding
  ↓
publishing
  ↓
healthy
```

## 5.5 Nessun cambiamento

```text
polling
  ↓
NO_CHANGE
  ↓
idle
```

Nessun nuovo artefatto viene creato.

---

# 6. EVENTI RUNTIME

## 6.1 Eventi provider normalizzati

```text
ProviderMatchUpdateReceived
ProviderMatchUpdateRejected
ProviderMatchUpdateDuplicate
```

## 6.2 Eventi match

```text
MatchBecameImminent
MatchStarted
MatchScoreChanged
MatchEnteredHalftime
MatchResumed
MatchFinished
MatchPostponed
MatchCancelled
MatchAwarded
MatchKickoffChanged
```

## 6.3 Eventi pipeline

```text
LivePipelineRequested
LivePipelineStarted
LivePipelineCompleted
LivePipelineFailed
LiveSnapshotReady
LiveSnapshotPublished
LiveSnapshotPublicationFailed
```

## 6.4 Eventi round

```text
RoundEnteredLive
RoundLiveProgressChanged
RoundAwaitingFinalCalculation
RoundAwaitingCertification
RoundCertified
```

## 6.5 Eventi health

```text
ProviderDegraded
ProviderRecovered
RuntimeStateStale
RuntimeRecovered
DeadLetterCreated
```

---

# 7. POLLING ADATTIVO

## 7.1 Principio

La frequenza dipende dalla probabilità che il dato cambi e dal valore del cambiamento per l'utente.

## 7.2 Policy iniziale raccomandata

### Nessuna partita nelle successive 24 ore

```text
poll_interval = 6 ore
```

Serve solo a intercettare:

- cambi kickoff;
- rinvii;
- modifiche calendario.

### Partita tra 24 ore e 2 ore

```text
poll_interval = 30 minuti
```

### Partita tra 2 ore e 15 minuti

```text
poll_interval = 5 minuti
```

### Partita imminente, entro 15 minuti

```text
poll_interval = 60 secondi
```

### Partita live

```text
poll_interval = 10–15 secondi
```

Il valore reale deve rispettare:

- limiti provider;
- piano API;
- numero di competizioni;
- affidabilità del dato.

### Intervallo

```text
poll_interval = 20–30 secondi
```

### Fine partita non ancora stabile

```text
poll_interval = 30 secondi
stability_checks = 2 o 3
```

Serve a intercettare correzioni immediate del provider.

### Post-live stabile

```text
poll_interval = 5 minuti
```

fino a quando il round non è pronto per il calcolo finale.

### Round certificato

```text
poll_interval = stop
```

Restano soltanto sincronizzazioni amministrative o correttive esplicite.

## 7.3 Jitter

Aggiungere jitter limitato per evitare picchi simultanei.

```text
effective_interval =
base_interval ± small_jitter
```

## 7.4 Scheduler persistente

Il piano di polling deve essere ricostruibile dal database.

Non deve dipendere esclusivamente dalla memoria del processo.

---

# 8. PIPELINE LIVE AUTOREVOLE

## 8.1 Trigger

La pipeline viene richiesta soltanto dopo una modifica significativa persistita.

## 8.2 Sequenza

```text
1. Acquire execution lock
2. Re-read authoritative Match State
3. Resolve affected FantaGol Round
4. Resolve affected League Rounds
5. Build or reuse Calculation Run
6. Build Points Preview
7. Build Fantacalcio branch
8. Build One-to-One branch
9. Merge Standings Preview
10. Build UI Snapshot
11. Build Live State Snapshot
12. Mark previous publication superseded
13. Publish new snapshot
14. Release lock
```

## 8.3 Source Simulation

Il Live Runtime non costruisce manualmente il Digital Twin.

Invoca i Builder ufficiali.

## 8.4 Partial failure

Una pipeline incompleta non viene pubblicata.

```text
Calculation Run OK
Points OK
Fantacalcio FAILED
        ↓
NO PUBLICATION
```

Lo snapshot precedente resta attivo.

## 8.5 Retry

Il retry deve riutilizzare:

- correlation_id;
- idempotency key;
- match update identity;
- source payload hash.

---

# 9. CONCORRENZA E IDEMPOTENZA

## 9.1 Identità aggiornamento provider

Chiave raccomandata:

```text
provider_code
external_match_id
provider_updated_at
source_payload_hash
```

## 9.2 Pipeline key

```text
league_round_id
authoritative_match_state_version
simulation_engine_version
```

## 9.3 Lock

Utilizzare uno dei seguenti meccanismi:

- PostgreSQL advisory lock;
- row lock;
- unique runtime job key;
- coda con consumer esclusivo.

## 9.4 Aggiornamenti ravvicinati

Quando arriva un nuovo aggiornamento mentre una pipeline precedente è in corso:

```text
do not publish obsolete version
```

Policy raccomandata:

```text
coalesce pending updates
rebuild from latest authoritative state
```

Non è necessario completare e pubblicare ogni stato intermedio ricevuto.

## 9.5 Monotonic version

Ogni pubblicazione per `league_round_id` deve avere una versione crescente.

Il client ignora:

```text
incoming_version <= applied_version
```

---

# 10. LIVE STATE SNAPSHOT

## 10.1 Identità

```text
live_snapshot_id
league_round_id
round_simulation_id
ui_snapshot_version
live_state_version
source_match_state_version
status
generated_at
published_at
input_hash
output_hash
```

## 10.2 Contenuto

```text
manifest
round_live_state
matches_live_state
member_live_state
mode_live_state
ui_snapshot_reference
timeline_cursor
health
```

## 10.3 Regola

Il Live State Snapshot non duplica l'intero Digital Twin quando può riferirsi alla Round Simulation.

Può contenere:

```text
round_simulation_id
ui_snapshot_hash
```

più i metadati runtime necessari.

## 10.4 Stati

```text
building
ready
published
superseded
invalidated
failed
certified
```

## 10.5 Immutabilità

Dopo `published`, lo snapshot non viene sovrascritto.

Una variazione produce una nuova versione.

---

# 11. PUBBLICAZIONE REALTIME

## 11.1 Source of truth

Il messaggio realtime non è l'unica fonte autorevole.

Contiene almeno:

```text
league_round_id
live_snapshot_id
round_simulation_id
version
status
published_at
```

## 11.2 Strategia client

Alla ricezione:

```text
if incoming.version > local.version:
    fetch/apply snapshot
else:
    ignore
```

## 11.3 Atomicità

La pubblicazione avviene soltanto dopo il commit completo dello snapshot.

## 11.4 Event loss

Quando:

- il client torna online;
- la websocket si riconnette;
- l'app Android riprende dal background;
- la pagina viene ricaricata;

deve richiedere l'ultimo snapshot completo.

## 11.5 Nessun aggiornamento parziale

Non pubblicare messaggi indipendenti come:

```text
score changed
icon changed
standing changed
```

senza un riferimento comune di versione.

---

# 12. CONTRATTO WEB E ANDROID

## 12.1 Identico dominio

Web e Android consumano gli stessi contratti:

```text
UI Snapshot
Live State Snapshot
Latest Publication
```

## 12.2 Cache locale

Il client può conservare:

```text
league_round_id
live_snapshot_id
version
payload
received_at
```

## 12.3 Stato offline

Se offline:

- mostrare l'ultimo snapshot noto;
- indicare dati non aggiornati;
- non simulare lo stato live;
- non ricalcolare;
- riallinearsi al ritorno online.

## 12.4 Background Android

Quando l'app entra in background:

- la websocket può essere sospesa;
- non serve mantenere polling aggressivo client-side;
- al resume si richiede l'ultimo snapshot;
- le notifiche push possono segnalare eventi importanti.

## 12.5 Frontend rendering

Il client applica il contratto visuale già prodotto.

### Pre-live

```text
match_phase = pre_live
visual_state = dormant
animation_state = none
```

### Live

```text
match_phase = live
visual_state = live
animation_state = soft_pulse
```

La pulsazione è applicata al contenitore complessivo della partita.

### Post-live / Certified

```text
visual_state = acquired
animation_state = none
```

### Icone

```text
off
candidate
live_active
live_inactive
on
```

Nessun client introduce stati aggiuntivi autonomamente.

---

# 13. TIMELINE E REPLAY

## 13.1 Timeline autorevole

Registrare gli eventi significativi con:

```text
event_id
event_type
match_id
league_round_id nullable
occurred_at
received_at
processed_at
provider
correlation_id
source_payload_hash
```

## 13.2 Replay futuro

La Timeline deve permettere in futuro di:

- ricostruire la sequenza della giornata;
- analizzare ritardi provider;
- riprodurre cambi punteggio e icone;
- confrontare snapshot;
- alimentare analytics.

## 13.3 Non ogni polling è un evento

Un polling senza variazione non entra nella Timeline di dominio.

Può essere conservato soltanto come metrica tecnica aggregata.

---

# 14. FAILURE MANAGEMENT

## 14.1 Classi di errore

```text
provider_timeout
provider_rate_limit
provider_invalid_payload
provider_mapping_missing
match_state_conflict
pipeline_calculation_failed
simulation_builder_failed
publication_failed
runtime_lock_timeout
stale_state
```

## 14.2 Provider failure

Se il provider non risponde:

- mantenere l'ultimo snapshot pubblicato;
- non inventare aggiornamenti;
- marcare health come degraded;
- aumentare progressivamente il retry interval;
- recuperare quando il provider torna disponibile.

## 14.3 Pipeline failure

Se il rebuild fallisce:

- non invalidare lo snapshot attivo;
- registrare failure;
- retry con stessa correlation;
- dead-letter dopo soglia configurata.

## 14.4 Publication failure

Se lo snapshot è pronto ma la pubblicazione fallisce:

- lo snapshot resta persistito;
- il publisher può ritentare;
- il client può comunque recuperarlo tramite query.

## 14.5 Stale threshold

Stato stale configurabile.

Esempio iniziale durante il live:

```text
last_successful_provider_update > 90 secondi
```

Il client può mostrare:

```text
aggiornamento in ritardo
```

senza alterare il risultato visualizzato.

---

# 15. PROVIDER STRATEGY

## 15.1 MVP

Provider calendario/live iniziale:

```text
football_data
```

Il Runtime deve comunque restare provider-agnostic.

## 15.2 Fallback

Il fallback provider deve essere esplicito e tracciato.

Non mescolare silenziosamente dati incompatibili.

Ogni aggiornamento conserva:

```text
provider_code
provider_priority
provider_updated_at
source_payload_hash
```

## 15.3 Conflict resolution

In caso di conflitto:

```text
primary provider
verified fallback
manual admin override
```

La scelta deve essere auditabile.

## 15.4 Quote

Le quote pre-match non appartengono al polling live dei risultati.

Il Bonus Sorpresa consuma lo snapshot quote già congelato secondo l'Odds Engine.

---

# 16. SECURITY

## 16.1 Credenziali

Le API key provider restano esclusivamente server-side.

## 16.2 Endpoint runtime

Gli endpoint di ingestione e rebuild devono essere protetti da:

- service role;
- secret;
- firma;
- controllo origine;
- rate limit;
- audit.

## 16.3 Client authorization

Il client riceve solo snapshot relativi a leghe accessibili.

## 16.4 No client writes

Web e Android non possono:

- cambiare Match State;
- attivare manualmente la pipeline live;
- pubblicare snapshot;
- alterare versioni;
- certificare risultati.

---

# 17. OBSERVABILITY

## 17.1 Metriche minime

```text
poll_requests_total
poll_success_total
poll_failure_total
provider_latency_ms
meaningful_updates_total
duplicate_updates_total
pipeline_duration_ms
pipeline_failure_total
publication_duration_ms
publication_failure_total
live_snapshot_age_seconds
active_live_matches
active_live_rounds
```

## 17.2 Log strutturato

Ogni esecuzione registra:

```text
job_id
correlation_id
provider
match_id
league_round_id
stage
status
duration_ms
error_code
```

## 17.3 Dashboard tecnica

Vista minima:

- provider health;
- partite live;
- ultimo polling;
- ultimo aggiornamento;
- round in rebuild;
- snapshot pubblicati;
- errori;
- dead letters.

---

# 18. COMMUNITY INTELLIGENCE

## 18.1 Separazione

Il Live Runtime non calcola indicatori Community.

Può emettere eventi e riferimenti che attivano il Community Intelligence Runtime.

## 18.2 Pre-live

Gli snapshot community vengono congelati al lock.

## 18.3 Live

Il live può confrontare:

```text
frozen pre-live consensus
vs
current real result
```

senza modificare il consenso originario.

## 18.4 Post-live

Gli indicatori di accuratezza vengono costruiti dopo il risultato acquisito o certificato.

## 18.5 Priorità

Community Intelligence non deve rallentare la pipeline critica dei punteggi live.

È una dipendenza asincrona e non bloccante.

---

# 19. NOTIFICHE

## 19.1 Eventi candidati

```text
RoundEnteredLive
MatchStarted
ExactActivated
SurpriseActivated
MatchFinished
RoundAwaitingCertification
RoundCertified
```

## 19.2 Deduplicazione

Ogni notifica usa una chiave idempotente.

Esempio:

```text
user_id
match_id
event_type
state_version
```

## 19.3 Non bloccante

Il fallimento delle notifiche non blocca:

- pipeline;
- snapshot;
- pubblicazione;
- certificazione.

---

# 20. DEPLOYMENT TARGET

## 20.1 MVP consigliato

```text
Supabase PostgreSQL
Supabase Realtime
Next.js server-only runtime
Vercel Cron per scheduler non-live
runtime worker idoneo per polling live
```

## 20.2 Vincolo Vercel

Le funzioni serverless non devono essere trattate come processi permanenti affidabili.

Il polling live richiede un modello compatibile con:

- cron frequente consentito;
- queue/worker;
- scheduled Edge Function;
- servizio runtime dedicato.

La scelta concreta deve essere verificata rispetto ai limiti correnti del piano hosting prima dell'implementazione.

## 20.3 Separazione implementativa

```text
lib/live-runtime/
  types.ts
  scheduler.ts
  provider-poller.ts
  normalizer.ts
  change-detector.ts
  orchestrator.ts
  publisher.ts
  recovery.ts
  health.ts
  errors.ts

app/api/internal/live/
  poll/route.ts
  rebuild/route.ts
  publish/route.ts
  health/route.ts

supabase/migrations/
  048_live_runtime_foundation.sql
```

---

# 21. DATABASE FOUNDATION PREVISTA

La Migration 048 può introdurre esclusivamente la fondazione persistente del Runtime.

## 21.1 Tabelle candidate

```text
live_runtime_jobs
live_match_update_receipts
live_state_snapshots
live_state_publications
live_runtime_dead_letters
```

## 21.2 Funzioni candidate

```text
register_live_match_update_rpc
claim_live_runtime_job_rpc
complete_live_runtime_job_rpc
fail_live_runtime_job_rpc
publish_live_state_snapshot_rpc
get_latest_live_state_snapshot_rpc
get_my_live_state_rpc
```

## 21.3 Cosa non deve contenere la Migration 048

- loop di polling;
- timer persistenti in sessione;
- chiamate HTTP provider dal database;
- CSS;
- animazioni;
- logica React;
- calcolo duplicato di scoring;
- calcolo duplicato di standings.

---

# 22. CONTRATTO JOB

## 22.1 Job types

```text
poll_match
refresh_round
rebuild_league_round
publish_snapshot
retry_publication
evaluate_certification_readiness
```

## 22.2 Stati

```text
pending
claimed
running
completed
failed
retry_wait
dead_letter
cancelled
```

## 22.3 Campi minimi

```text
job_id
job_type
scope_type
scope_id
priority
scheduled_at
claimed_at
claimed_by
attempt_count
max_attempts
idempotency_key
correlation_id
payload
status
last_error
created_at
completed_at
```

## 22.4 Claim atomico

Più worker non devono eseguire lo stesso job.

Usare:

```text
FOR UPDATE SKIP LOCKED
```

oppure meccanismo equivalente.

---

# 23. CONTRATTO UPDATE RECEIPT

## 23.1 Scopo

Deduplicare gli aggiornamenti provider.

## 23.2 Campi minimi

```text
receipt_id
provider_id
external_match_id
internal_match_id
provider_updated_at
payload_hash
received_at
normalized_payload
meaningful_change
processing_status
correlation_id
```

## 23.3 Unicità

```text
provider_id
external_match_id
provider_updated_at
payload_hash
```

---

# 24. CONTRATTO PUBBLICAZIONE

## 24.1 Campi minimi

```text
publication_id
league_round_id
live_state_snapshot_id
round_simulation_id
version
channel
payload_hash
status
published_at
superseded_at
```

## 24.2 Unica pubblicazione attiva

Per ogni:

```text
league_round_id + channel
```

può esistere una sola pubblicazione attiva.

## 24.3 Append-only

Una nuova pubblicazione supersede la precedente.

Non la sovrascrive.

---

# 25. TEST STRATEGY

## 25.1 Test puro

- normalizzazione provider;
- change detection;
- mapping stato;
- polling policy;
- deduplicazione;
- version comparison.

## 25.2 Test database

```text
BEGIN
→ register update
→ claim job
→ build pipeline
→ create live snapshot
→ publish
→ verify active publication
→ ROLLBACK
```

## 25.3 Test concorrenza

- due worker sullo stesso job;
- due aggiornamenti ravvicinati;
- duplicate provider payload;
- pipeline obsoleta;
- pubblicazione concorrente.

## 25.4 Test recovery client

- perdita evento realtime;
- reconnect;
- resume Android;
- snapshot locale vecchio;
- versione ricevuta fuori ordine.

## 25.5 Test visuale

### Pre-live

- card dormant;
- nessuna pulsazione;
- icone off;
- solo Sorpresa candidate possibile.

### Live

- intera card in soft pulse;
- squadre, risultato e pronostico inclusi;
- icone live_active/live_inactive dinamiche.

### Post-live / Certified

- card statica acquired;
- risultato fisso;
- icone on/off definitive.

---

# 26. ORDINE DI IMPLEMENTAZIONE

## Step 1

Congelare questo Live Runtime Master.

## Step 2

Ispezionare hosting, limiti provider e capacità realtime correnti.

## Step 3

Disegnare la Migration 048 Live Runtime Foundation.

## Step 4

Creare tabelle job, receipt, snapshot, publication e dead letter.

## Step 5

Creare RPC service-only e query authenticated.

## Step 6

Implementare moduli TypeScript puri:

```text
normalizer
change detector
poll policy
orchestrator contract
```

## Step 7

Implementare il provider poll worker.

## Step 8

Collegare la Simulation Platform 040–047.

## Step 9

Implementare Supabase Realtime publication e recovery query.

## Step 10

Test transazionale, concorrenza e recovery.

## Step 11

Collegare il frontend web.

## Step 12

Riutilizzare gli stessi contratti nell'app Android.

---

# 27. DECISIONI CONGELATE

1. Il Live Runtime non calcola il dominio.
2. Il client non interroga provider.
3. Solo aggiornamenti significativi avviano rebuild.
4. Ogni pubblicazione è versionata e coerente.
5. Il client può sempre recuperare l'ultimo snapshot.
6. La Simulation Platform 040–047 resta la pipeline ufficiale.
7. La pulsazione esiste soltanto nello stato live.
8. Durante il live pulsa l'intero evento.
9. Le icone si accendono e spengono senza animazione autonoma.
10. Pre-live e post-live sono statici.
11. Il Bonus Sorpresa candidate è l'unica eccezione luminosa pre-live.
12. Post-live e certified restano distinti logicamente ma condividono lo stesso comportamento visivo.
13. Community Intelligence e notifiche sono asincrone e non bloccanti.
14. Il database persiste stato, job, snapshot e pubblicazioni.
15. Timer e chiamate provider appartengono al runtime applicativo.

---

# 28. DIRETTIVA FINALE

Il Live Runtime deve rendere FantaGol vivo senza rendere il dominio fragile.

Deve essere:

- provider-agnostic;
- idempotente;
- recuperabile;
- osservabile;
- versionato;
- coerente;
- efficiente;
- compatibile con Web e Android;
- indipendente dal processo runtime specifico;
- fedele al linguaggio visivo minimale di FantaGol.

```text
Provider changes reality
        ↓
FantaGol rebuilds truth
        ↓
Runtime publishes one coherent version
        ↓
Every client renders the same game
```
