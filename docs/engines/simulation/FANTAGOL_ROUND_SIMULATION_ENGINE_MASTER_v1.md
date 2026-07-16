# FANTAGOL ROUND SIMULATION ENGINE MASTER v1

**Stato:** documento fondativo operativo  
**Ambito:** composizione delle preview di giornata e costruzione del Digital Twin FantaGol  
**Obiettivo:** trasformare gli output dei motori di dominio in una rappresentazione completa, versionata e consumabile dai client, senza ricalcolare le regole del gioco e senza produrre ufficialità.

---

# 0. PRINCIPI FONDATIVI

## 0.1 Responsabilità unica

Il Round Simulation Engine costruisce la rappresentazione completa di una giornata FantaGol.

Possiede e governa:

- Round Simulation;
- Simulation Manifest;
- Digital Twin;
- Simulation Builder Registry;
- Points Preview;
- Fantacalcio Preview;
- One To One Preview;
- Standings Preview;
- UI Snapshot;
- Analytics Seed Snapshot.

Non possiede:

- pronostici;
- strategie;
- risultati reali;
- regole di scoring;
- classifiche ufficiali;
- ledger;
- certificazioni;
- provider live.

## 0.2 Il motore compone, non ricalcola

Il Round Simulation Engine non determina:

- Exact;
- Segno;
- Over/Under;
- Goal/No Goal;
- Bonus;
- Malus;
- punti base;
- validità delle strategie.

Queste informazioni devono essere consumate dagli artefatti prodotti dai motori autorevoli.

```text
CORE OUTPUTS
     ↓
ROUND SIMULATION ENGINE
     ↓
DIGITAL TWIN
     ↓
WEB / ANDROID / CONTROL ROOM
```

## 0.3 Tutto ciò che precede la certificazione è preview

Ogni output non certificato deve essere esplicitamente identificabile come provvisorio.

```text
preview = true
status = preview_ready
```

La preview può cambiare.

Il dato certificato no.

## 0.4 Il Digital Twin è immutabile

Ogni variazione significativa genera una nuova versione della simulazione.

Il sistema non sovrascrive la fotografia precedente.

```text
NUOVO RISULTATO
      ↓
NUOVO CALCULATION RUN
      ↓
NUOVA ROUND SIMULATION
      ↓
NUOVO DIGITAL TWIN
```

## 0.5 I client non ricostruiscono il dominio

Web, Android e futuri client devono ricevere oggetti già pronti per la rappresentazione.

La UI non deve:

- ricalcolare punteggi;
- derivare stati;
- decidere quali icone accendere;
- ricostruire classifiche;
- interpretare transizioni di dominio.

---

# 1. ENGINE CONTRACT

## 1.1 Nome

```text
RoundSimulationEngine
```

## 1.2 Artefatto principale

```text
RoundSimulation
```

## 1.3 Input autorevoli

```text
CalculationRun
PredictionScoreRuntimeResults
MatchSetSnapshot
StrategySnapshot
LeagueRound
LeagueScoringProfile
LeagueFixtures
MatchStateSnapshot
```

## 1.4 Output

```text
RoundSimulation
SimulationManifest
BuilderExecutionRegistry
PointsPreview
FantacalcioPreview
OneToOnePreview
StandingsPreview
UISnapshot
AnalyticsSeedSnapshot
```

## 1.5 Comandi accettati

```text
BuildRoundSimulation
RebuildRoundSimulation
InvalidateRoundSimulation
MarkSimulationAwaitingCertification
AttachCertifiedReference
ArchiveRoundSimulation
```

## 1.6 Eventi emessi

```text
RoundSimulationBuilding
RoundSimulationReady
RoundSimulationInvalidated
RoundSimulationAwaitingCertification
RoundSimulationCertified
RoundSimulationArchived
SimulationBuilderCompleted
SimulationBuilderFailed
```

## 1.7 Query

```text
GetLatestRoundSimulation
GetRoundSimulationByVersion
GetRoundSimulationManifest
GetRoundSimulationBuilders
GetMyRoundSimulationView
GetLeagueRoundSimulationView
```

---

# 2. POSIZIONE NELL'ARCHITETTURA

```text
Prediction Engine
Strategy Engine
Resolution Engine
Match State
      │
      ▼
ROUND SIMULATION ENGINE
      │
      ├── Points Preview
      ├── Fantacalcio Preview
      ├── One To One Preview
      ├── Standings Preview
      ├── UI Snapshot
      └── Analytics Seed
      │
      ▼
Live State Engine
      │
      ▼
Experience Layer
```

Il Round Simulation Engine rappresenta il confine tra il dominio operativo e l'esperienza utente.

---

# 3. ROUND SIMULATION

## 3.1 Definizione

La Round Simulation è la fotografia completa e coerente di una giornata FantaGol in un preciso istante.

Contiene:

- identità della giornata;
- versione della simulazione;
- origine dei dati;
- stato della preview;
- risultati parziali;
- viste per modalità;
- stato grafico;
- riferimenti di integrità.

## 3.2 Identità

Ogni simulazione deve essere identificata almeno da:

```text
simulation_id
league_round_id
calculation_run_id
simulation_version
engine_version
created_at
status
preview
```

## 3.3 Relazione con Calculation Run

Una Round Simulation deriva sempre da un Calculation Run preciso.

Non può esistere una simulazione priva di origine matematica tracciabile.

```text
CalculationRun 1
      ↓
RoundSimulation 1

CalculationRun 2
      ↓
RoundSimulation 2
```

## 3.4 Versione

La versione cresce in modo monotono all'interno della stessa giornata di lega.

```text
league_round_id + simulation_version
```

deve essere univoco.

## 3.5 Stati

```text
building
preview_ready
preview_invalidated
awaiting_certification
certified
archived
failed
```

## 3.6 Transizioni valide

```text
building → preview_ready
building → failed
preview_ready → preview_invalidated
preview_ready → awaiting_certification
preview_invalidated → archived
awaiting_certification → certified
certified → archived
```

## 3.7 Transizioni vietate

```text
certified → building
archived → preview_ready
failed → certified
preview_invalidated → certified
```

---

# 4. SIMULATION MANIFEST

## 4.1 Scopo

Il Simulation Manifest è la carta d'identità tecnica e funzionale della simulazione.

## 4.2 Campi logici minimi

```text
engine
engine_version
simulation_id
simulation_version
league_round_id
calculation_run_id
resolution_version
match_set_version
strategy_version
scoring_profile_version
preview
generated_at
input_hash
output_hash
status
```

## 4.3 Integrità

Il Manifest deve rendere possibile:

- verificare l'origine;
- confrontare due simulazioni;
- individuare la versione visualizzata;
- riconoscere una preview invalidata;
- collegare la simulazione alla certificazione finale.

## 4.4 Hash

Gli hash devono essere deterministici rispetto agli input canonici e all'output canonico.

Stessi input e stessa versione del motore devono produrre lo stesso output hash.

---

# 5. DIGITAL TWIN

## 5.1 Definizione

Il Digital Twin è l'artefatto consumabile che rappresenta la giornata.

Non è la giornata reale.

È la sua rappresentazione applicativa completa.

## 5.2 Contenuto

```text
manifest
round
matches
members
competitions
standings
ui
analytics_seed
```

## 5.3 Round View

Contiene:

```text
round_number
round_status
match_count
started_matches
live_matches
finished_matches
pending_matches
progress_percent
opens_at
lock_at
starts_at
completed_at nullable
```

## 5.4 Match View

Per ogni partita:

```text
match_id
slot_number
teams
kickoff
status
score
result_phase
included
postponed
certified
member_prediction_view
member_score_view
icon_state
visual_state
```

## 5.5 Member View

Per ogni membro:

```text
league_member_id
round_points
exact_count
bonus_count
malus_count
mode_previews
ranking_preview
score_phase
visual_state
```

## 5.6 Coerenza

Tutti i sotto-oggetti di un Digital Twin devono riferirsi alla stessa versione della simulazione.

Non è ammesso comporre una schermata usando frammenti appartenenti a simulazioni differenti.

---

# 6. BUILDER REGISTRY

## 6.1 Principio

La simulazione è costruita da builder indipendenti.

```text
PointsPreviewBuilder
FantacalcioPreviewBuilder
OneToOnePreviewBuilder
StandingsPreviewBuilder
UISnapshotBuilder
AnalyticsSeedBuilder
```

## 6.2 Registro esecuzioni

Ogni builder registra:

```text
builder_name
builder_version
status
started_at
completed_at
input_hash
output_hash
error_code nullable
metadata
```

## 6.3 Stati builder

```text
pending
running
completed
failed
skipped
```

## 6.4 Dipendenze

```text
Points Preview
      ↓
Fantacalcio Preview
One To One Preview
      ↓
Standings Preview
      ↓
UI Snapshot
```

Analytics Seed può dipendere dagli artefatti già disponibili ma non deve influenzare gli altri builder.

## 6.5 Fallimento

Il fallimento di un builder obbligatorio impedisce lo stato `preview_ready`.

Un builder opzionale può essere marcato `skipped` senza invalidare l'intera simulazione.

---

# 7. POINTS PREVIEW BUILDER

## 7.1 Input

```text
PredictionScoreRuntimeResults
```

## 7.2 Responsabilità

Aggregare i risultati per:

- membro;
- partita;
- giornata;
- componente;
- fase.

## 7.3 Output minimo

```text
member_round_total
match_score_rows
exact_count
sign_count
over_under_count
goal_no_goal_count
surprise_count
goal_show_count
grand_slam_count
opposite_sign_count
cantonata_count
missing_count
void_count
```

## 7.4 Regola

Il builder non modifica il punteggio.

Somma e organizza esclusivamente valori già prodotti dal Resolution Engine.

---

# 8. FANTACALCIO PREVIEW BUILDER

## 8.1 Input

```text
PointsPreview
FantacalcioStrategySnapshot
LeagueFixture
FantacalcioRuleset
```

## 8.2 Responsabilità

Produrre:

- punteggio strategico;
- conversione in gol;
- risultato provvisorio del fixture;
- statistiche Attacco e Difesa.

## 8.3 Output minimo

```text
home_member_id
away_member_id
home_points
away_points
home_goals
away_goals
fixture_phase
attack_breakdown
defense_breakdown
result
```

## 8.4 Confine

Il builder non ricalcola il punteggio base.

Applica esclusivamente il ruleset di modalità già versionato agli output autorevoli.

---

# 9. ONE TO ONE PREVIEW BUILDER

## 9.1 Input

```text
PredictionScoreRuntimeResults
OneToOneStrategySnapshots
LeagueFixture
OneToOneRuleset
```

## 9.2 Responsabilità

Produrre:

- due matrici;
- mini-sfide;
- esiti provvisori;
- risultato aggregato.

## 9.3 Output minimo

```text
matrix_a
matrix_b
mini_wins
mini_draws
mini_losses
aggregate_result
fixture_phase
```

## 9.4 Riservatezza

Prima del lock, le strategie avversarie non devono essere esposte.

Dopo il lock, la visibilità segue il ruleset ufficiale.

---

# 10. STANDINGS PREVIEW BUILDER

## 10.1 Principio

Le classifiche prodotte dal Simulation Engine sono provvisorie.

Non aggiornano il ledger.

## 10.2 Input

```text
OfficialStandingBaseline
PointsPreview
FantacalcioPreview
OneToOnePreview
```

## 10.3 Output

```text
mode
position_preview
movement_preview
competition_points_preview
raw_points_preview
tiebreaker_preview
baseline_reference
```

## 10.4 Vincolo

Le classifiche preview devono essere chiaramente distinguibili dalle classifiche ufficiali.

---

# 11. UI SNAPSHOT BUILDER

## 11.1 Missione

Trasformare gli stati di dominio in stati di presentazione già pronti.

## 11.2 Match Phase

```text
pre_live
live
post_live
certified
postponed
void
```

## 11.3 Score Phase

```text
waiting
provisional
final_pending_commit
locked
```

## 11.4 Icon State

```text
off
candidate
live_active
on
locked_on
locked_off
```

## 11.5 Animation State

```text
none
soft_pulse
score_pulse
transition
```

## 11.6 Bonus Sorpresa

Il Bonus Sorpresa possiede uno stato pre-live distinto.

```text
candidate
```

In questo stato:

- il centro dell'icona resta spento;
- il cerchio esterno è acceso;
- il sistema comunica potenziale eleggibilità;
- non comunica assegnazione.

Durante il live segue le regole dinamiche comuni.

A risultato acquisito resta acceso soltanto se effettivamente ottenuto.

## 11.7 Regola generale delle icone

Pre-live:

```text
icone spente
eccezione: alone esterno Sorpresa candidate
```

Live:

```text
icone dinamiche
lieve pulsazione
stato provvisorio
```

Post-live:

```text
icone statiche
accese solo se effettivamente ottenute
```

Certified:

```text
icone statiche bloccate
```

## 11.8 Regola dell'evento

L'intera card partita deve comunicare la fase:

- futura;
- in corso;
- conclusa;
- certificata.

La distinzione deve essere prevalentemente grafica e intuitiva.

---

# 12. ANALYTICS SEED SNAPSHOT

## 12.1 Scopo

Preparare dati ordinati per i futuri motori Analytics senza calcolare indicatori avanzati.

## 12.2 Contenuto minimo

```text
prediction_count
strategy_count
consensus_distribution
surprise_candidate_count
attack_usage_count
defense_usage_count
one_to_one_pairing_count
snapshot_generated_at
```

## 12.3 Confine

Il Round Simulation Engine esporta dati strutturati.

Non interpreta:

- qualità predittiva;
- momentum;
- chaos;
- confidence;
- raccomandazioni.

---

# 13. INVALIDAZIONE

## 13.1 Cause

Una simulazione può essere invalidata quando cambia:

- Calculation Run;
- Match Set Version;
- Strategy Snapshot;
- Scoring Profile;
- risultato reale;
- decisione rinvio;
- ruleset di modalità.

## 13.2 Effetto

La simulazione precedente resta conservata ma non deve essere proposta come corrente.

## 13.3 Latest valid

La query corrente deve restituire esclusivamente l'ultima simulazione valida e pubblicabile.

---

# 14. CERTIFICATION HANDOFF

## 14.1 Principio

Il Simulation Engine non certifica.

Prepara l'artefatto candidato.

## 14.2 Passaggio

```text
Latest Valid Simulation
      ↓
Certification Engine
      ↓
Certified Artifact
      ↓
Ledger
```

## 14.3 Stato awaiting_certification

Viene usato quando:

- tutti i match richiesti sono conclusi;
- il Calculation Run è completo;
- tutti i builder obbligatori sono completati;
- non esistono invalidazioni pendenti.

## 14.4 Collegamento finale

Dopo la certificazione, la simulazione può essere collegata a:

```text
certification_id
ledger_version
certified_at
```

---

# 15. SICUREZZA E VISIBILITÀ

## 15.1 Visibilità membro

Un membro può leggere simulazioni della propria lega secondo le policy vigenti.

## 15.2 Dati privati

Prima del lock non devono essere esposti:

- pronostici altrui;
- strategie altrui;
- matrici One To One altrui.

## 15.3 Service role

La costruzione e l'invalidazione delle simulazioni appartengono a percorsi controllati.

## 15.4 Nessuna scrittura client

I client non possono creare o modificare Round Simulation.

---

# 16. DETERMINISMO E IDEMPOTENZA

## 16.1 Determinismo

Stessi input canonici e stessa versione builder producono lo stesso output.

## 16.2 Idempotenza

La richiesta ripetuta sullo stesso Calculation Run non deve produrre simulazioni duplicate equivalenti.

## 16.3 Concorrenza

Una sola simulazione può essere costruita per la stessa combinazione:

```text
league_round_id
calculation_run_id
engine_version
```

---

# 17. READ MODELS

Read model iniziali:

```text
latest_round_simulation_view
round_simulation_manifest_view
round_simulation_match_view
round_simulation_member_view
round_simulation_mode_view
round_simulation_ui_view
```

Le view devono essere ottimizzate per lettura e non diventare fonte di regole di business.

---

# 18. OSSERVABILITÀ

Metriche minime:

```text
round_simulation_build_total
round_simulation_build_failed
round_simulation_build_duration
builder_execution_duration
simulation_invalidated_total
latest_simulation_age
simulation_output_size
```

Log minimi:

```text
simulation_id
league_round_id
calculation_run_id
builder_name
builder_version
status
correlation_id
error_code
```

---

# 19. EVOLUZIONE PREVISTA

## 19.1 Versione 1.x

- Digital Twin Web;
- Digital Twin Android;
- preview delle tre modalità;
- UI Snapshot;
- integrazione Live State.

## 19.2 Evoluzioni future

- notifiche derivate dal Digital Twin;
- widget;
- API pubbliche;
- AI Coach;
- simulazioni alternative;
- confronto tra versioni;
- replay completo della giornata.

Tali evoluzioni non devono modificare il Core.

---

# 20. DECISIONI CONGELATE

- Il Simulation Engine non ricalcola le regole di scoring.
- Ogni simulazione deriva da un Calculation Run.
- Il Digital Twin è immutabile e versionato.
- Ogni variazione significativa produce una nuova simulazione.
- Web e Android consumano lo stesso artefatto.
- La UI non implementa regole di business.
- Le classifiche prodotte dal Simulation Engine sono preview.
- Il Bonus Sorpresa possiede lo stato pre-live `candidate`.
- Il Live State Engine consuma la simulazione, non la sostituisce.
- La certificazione appartiene a un motore separato.

---

# DIRETTIVA FINALE

Il Round Simulation Engine deve rappresentare la giornata senza alterarla.

Il suo compito è organizzare la verità prodotta dai motori di dominio in un artefatto completo, coerente, versionato e immediatamente consumabile.

Ogni client FantaGol deve poter raccontare la stessa giornata leggendo lo stesso Digital Twin, senza duplicare calcoli, interpretazioni o regole.
