# FANTAGOL COMPETITION ENGINE MASTER v1

**Stato:** documento fondativo operativo  
**Ambito:** gestione universale di competizioni, edizioni, fasi, squadre, partite e FantaGol Round  
**Obiettivo:** tradurre il calendario calcistico reale in unità di gioco FantaGol coerenti, affidabili, versionate e indipendenti dal provider.

---

# 0. PRINCIPI FONDATIVI

## 0.1 Responsabilità unica

Il Competition Engine possiede e governa:

- Sport;
- Competition;
- Competition Edition;
- Competition Stage;
- Team;
- Match;
- Provider Round;
- FantaGol Round;
- FantaGol Round Match;
- Match Set;
- lifecycle temporale dei round.

Non possiede:

- pronostici;
- quote;
- scoring;
- strategie;
- classifiche;
- Control Room;
- Pass.

## 0.2 Competizione reale e gioco FantaGol restano separati

```text
COMPETITION
  ↓
COMPETITION EDITION
  ↓
COMPETITION STAGE
  ↓
PROVIDER ROUND
  ↓
MATCH
  ↓
FANTAGOL ROUND
  ↓
MATCH SET
```

Il Provider Round è un dato sorgente.

Il FantaGol Round è una decisione di prodotto.

## 0.3 International Ready, local launch

Architettura:

```text
supporta club e nazionali
supporta campionati e coppe
supporta gironi e knockout
supporta più lingue
supporta più provider
```

Lancio iniziale:

```text
sport_active = football
competition_active = Serie A
locale_active = it-IT
```

## 0.4 Identità interne stabili

Gli ID interni FantaGol non dipendono dagli ID provider.

## 0.5 Immutabilità dopo il lock

Dopo il lock:

- il Match Set non cambia;
- l'ordine degli slot non cambia;
- i match inclusi non cambiano;
- ogni modifica richiede procedura amministrativa e audit.

---

# 1. ENGINE CONTRACT

## 1.1 Nome

```text
CompetitionEngine
```

## 1.2 Owned Entities

```text
Sport
Competition
CompetitionEdition
CompetitionStage
Team
ProviderRound
Match
FantaGolRound
FantaGolRoundMatch
MatchSetVersion
```

## 1.3 Accepted Commands

```text
CreateCompetition
CreateCompetitionEdition
CreateCompetitionStage
RegisterTeam
ImportMatch
UpdateMatch
CreateFantaGolRound
ApproveMatchSet
OpenRound
LockRound
CancelRound
ReplaceMatchBeforeLock
RecalculateRoundSchedule
ActivateCompetition
DeactivateCompetition
```

## 1.4 Emitted Events

```text
CompetitionCreated
CompetitionActivated
CompetitionDeactivated
EditionCreated
StageCreated
TeamRegistered
MatchImported
MatchUpdated
FantaGolRoundCreated
MatchSetApproved
RoundOpened
RoundLocked
RoundCancelled
RoundScheduleChanged
MatchReplacedBeforeLock
```

## 1.5 Consumed Events

```text
ProviderCompetitionSynced
ProviderCalendarSynced
ProviderMatchUpdated
AdminRoundApproved
ClockReachedOpenAt
ClockReachedLockAt
```

## 1.6 Queries

```text
GetActiveCompetitions
GetCompetitionEdition
GetCompetitionStages
GetTeamsByEdition
GetMatchesByProviderRound
GetCurrentFantaGolRound
GetFantaGolRoundBySequence
GetRoundMatchSet
GetRoundLifecycleState
GetUpcomingMatches
```

---

# 2. MODELLO DI DOMINIO

## 2.1 Sport

```text
sport
- id
- code
- name_key
- active
- created_at
- updated_at
```

Vincoli:

- `code` univoco;
- almeno uno sport attivo;
- MVP: solo `football`.

## 2.2 Competition

```text
competition
- id
- sport_id
- code
- name_key
- short_name_key nullable
- country_code nullable
- confederation_code nullable
- competition_type
- scope
- gender
- active
- public
- beta
- launch_date nullable
- created_at
- updated_at
- version
```

Valori:

```text
competition_type:
- league
- domestic_cup
- continental_club
- national_team_tournament
- qualifier
- super_cup
- friendly_tournament

scope:
- domestic
- continental
- international

gender:
- male
- female
- mixed
```

## 2.3 Competition Edition

```text
competition_edition
- id
- competition_id
- label
- provider_label nullable
- year_start
- year_end nullable
- starts_at
- ends_at
- status
- active
- created_at
- updated_at
- version
```

Stati:

```text
draft
scheduled
active
completed
archived
cancelled
```

## 2.4 Competition Stage

```text
competition_stage
- id
- edition_id
- code
- name_key
- stage_type
- sequence
- starts_at nullable
- ends_at nullable
- active
- created_at
- updated_at
- version
```

Valori:

```text
regular_season
league_phase
group_stage
playoff
round_of_32
round_of_16
quarter_final
semi_final
final
qualifier
```

## 2.5 Team

```text
team
- id
- sport_id
- team_type
- code nullable
- name
- short_name nullable
- country_code nullable
- federation_code nullable
- crest_reference nullable
- active
- created_at
- updated_at
- version
```

Valori:

```text
team_type:
- club
- national_team
```

Nota:

- `crest_reference` è un riferimento interno o licenziato;
- non deve implicare il riuso non autorizzato di asset provider.

## 2.6 Edition Team

```text
edition_team
- edition_id
- team_id
- group_code nullable
- seed nullable
- active
- joined_at
- left_at nullable
```

Serve perché una squadra può partecipare a più edizioni e cambiare gruppo o fase.

## 2.7 Provider Round

```text
provider_round
- id
- provider_id
- edition_id
- stage_id nullable
- external_id
- name
- number nullable
- starts_at nullable
- ends_at nullable
- source_payload_hash nullable
- synced_at
- created_at
- updated_at
```

Vincoli:

- univocità per provider + external_id;
- non è automaticamente un FantaGol Round.

## 2.8 Match

```text
match
- id
- edition_id
- stage_id nullable
- provider_round_id nullable
- home_team_id
- away_team_id
- kickoff_at
- venue_name nullable
- status
- home_score nullable
- away_score nullable
- minute nullable
- period nullable
- provider_updated_at nullable
- finalised_at nullable
- active
- created_at
- updated_at
- version
```

Stati:

```text
scheduled
postponed
cancelled
live_first_half
halftime
live_second_half
extra_time
penalties
finished
awarded
abandoned
```

Vincoli:

- home_team_id ≠ away_team_id;
- risultato nullo quando `scheduled`;
- risultato obbligatorio per `finished` e `awarded`;
- kickoff salvato in UTC.

## 2.9 FantaGol Round

```text
fantagol_round
- id
- edition_id
- stage_id nullable
- name
- sequence
- target_match_count
- minimum_match_count
- maximum_match_count
- selection_policy
- opens_at
- lock_at
- starts_at
- ends_at nullable
- status
- active
- official_match_set_version
- created_at
- updated_at
- version
```

Stati:

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

## 2.10 FantaGol Round Match

```text
fantagol_round_match
- id
- fantagol_round_id
- match_id
- slot_number
- selection_reason
- source_provider_round_id nullable
- required
- included_at
- removed_at nullable
- version
```

Vincoli:

- match unico per round;
- slot unico per round;
- slot positivo;
- nessuna rimozione dopo lock senza procedura amministrativa.

## 2.11 Match Set Version

```text
match_set_version
- id
- fantagol_round_id
- version
- match_ids_ordered
- reason
- created_by
- created_at
- official
```

Serve a rendere il Match Set riproducibile e auditabile.

---

# 3. POLITICHE DI SELEZIONE

## 3.1 official_matchweek

Usa integralmente un turno ufficiale.

Caso ideale:

```text
Serie A
1 provider round
10 match
1 FantaGol Round
```

## 3.2 chronological_first_n

Seleziona i primi N match in ordine cronologico.

## 3.3 chronological_window

Seleziona i match in una finestra temporale.

## 3.4 provider_group

Usa un gruppo provider predefinito.

## 3.5 manual_admin

Selezione amministrativa manuale.

## 3.6 balanced_stage

Bilancia match provenienti da più gruppi o fasi.

## 3.7 custom_curated

Composizione editoriale esplicita.

## 3.8 Regola MVP Serie A

Per il lancio:

```text
selection_policy = official_matchweek
target_match_count = 10
minimum_match_count = 10
maximum_match_count = 10
```

---

# 4. ROUND BUILDER

## 4.1 Input

```text
edition_id
stage_id
provider_round_id nullable
selection_policy
target_match_count
opens_at policy
lock_at policy
```

## 4.2 Pipeline

```text
load candidate matches
→ validate match eligibility
→ sort deterministically
→ select matches
→ assign slot numbers
→ calculate starts_at
→ calculate lock_at
→ create draft round
→ create match set version
→ validate
→ approve
```

## 4.3 Ordinamento deterministico

Default:

```text
kickoff_at ASC
home_team_id ASC
match_id ASC
```

## 4.4 Match eligibility

Un match è eleggibile quando:

- appartiene all'edition;
- è attivo;
- non è cancelled;
- ha squadre valide;
- ha kickoff valido;
- non è già incluso in altro round incompatibile.

## 4.5 Requisiti modalità

Il Competition Engine non calcola le modalità.

Espone però capability:

```text
supports_points_pure
supports_fantacalcio
supports_one_to_one
```

Default:

```text
supports_points_pure = match_count >= 1
supports_fantacalcio = match_count == 10
supports_one_to_one = match_count == 10
```

---

# 5. ROUND VALIDATOR

## 5.1 Validazioni strutturali

- nessun duplicato;
- slot consecutivi;
- conteggio nei limiti;
- tutti i match appartenenti alla stessa edition;
- kickoff presenti;
- nessun match cancellato;
- ordine deterministico;
- lock_at ≤ starts_at;
- opens_at < lock_at.

## 5.2 Validazioni Serie A MVP

- esattamente 10 match;
- 20 team distinti quando il calendario ufficiale lo prevede;
- stesso provider round;
- stesso matchday;
- nessuna sovrapposizione con altro FantaGol Round attivo.

## 5.3 Error codes

```text
ROUND_MATCH_COUNT_INVALID
ROUND_DUPLICATE_MATCH
ROUND_DUPLICATE_SLOT
ROUND_MATCH_EDITION_MISMATCH
ROUND_MATCH_CANCELLED
ROUND_KICKOFF_MISSING
ROUND_LOCK_AFTER_START
ROUND_OPEN_AFTER_LOCK
ROUND_OVERLAPS_EXISTING
ROUND_NOT_SERIE_A_MATCHWEEK
```

---

# 6. SCHEDULER E LIFECYCLE

## 6.1 Apertura

Default MVP:

```text
opens_at = termine del round precedente o data amministrativa
```

## 6.2 Lock

Default:

```text
lock_at = kickoff della prima partita
```

## 6.3 Start

```text
starts_at = kickoff minimo del Match Set
```

## 6.4 End

```text
ends_at = conclusione dell'ultimo match richiesto
```

## 6.5 Transizioni valide

```text
draft → scheduled
scheduled → predictions_open
predictions_open → predictions_locked
predictions_locked → live
live → partial_finished
partial_finished → waiting_postponed
partial_finished → final_calculable
waiting_postponed → final_calculable
final_calculable → final_official
final_official → recalculated
```

## 6.6 Transizioni vietate

- final_official → predictions_open;
- cancelled → live;
- predictions_locked → draft;
- live → scheduled.

---

# 7. MATCH UPDATE ENGINE

## 7.1 Input provider

```text
external_match_id
status
kickoff
score
minute
provider_updated_at
payload_hash
```

## 7.2 Aggiornamento idempotente

La stessa versione provider non produce doppio aggiornamento.

## 7.3 Eventi significativi

```text
MatchImported
MatchKickoffChanged
MatchStarted
MatchScoreChanged
MatchStatusChanged
MatchFinished
MatchPostponed
MatchCancelled
```

## 7.4 Cosa non persistere

Non salvare una nuova versione a ogni polling se nulla cambia.

---

# 8. RINVII, ANNULLAMENTI E SOSTITUZIONI

## 8.1 Rinvio prima del lock

Il match può essere sostituito se:

- il round non è locked;
- esiste un match eleggibile;
- il nuovo Match Set passa la validazione;
- viene creata una nuova Match Set Version.

## 8.2 Rinvio dopo il lock

Il match resta nel round.

Il round passa eventualmente a:

```text
waiting_postponed
```

La policy di scoring sarà definita dal Game Engine e dal ruleset.

## 8.3 Annullamento prima del lock

Preferire sostituzione.

## 8.4 Annullamento dopo il lock

Nessuna sostituzione automatica.

Richiede:

- policy di gioco;
- audit;
- eventuale ricalcolo.

## 8.5 Cambio kickoff

Prima del lock:

- aggiornare schedule;
- ricalcolare lock se necessario;
- notificare gli utenti.

Dopo il lock:

- il lock non riapre automaticamente.

---

# 9. COMPETITION REGISTRY

## 9.1 Scopo

Elenco centrale delle competizioni supportate.

## 9.2 Stato prodotto

```text
enabled
public
beta
launch_date
priority
```

## 9.3 Lancio

Riga iniziale:

```text
Competition = Serie A
enabled = true
public = true
beta = true
locale = it-IT
```

## 9.4 Espansione futura

Aggiungere una competizione deve richiedere:

- Competition;
- Edition;
- Stage;
- Team;
- provider mapping;
- calendario;
- policy round;
- localizzazione;
- verifica licenze asset.

Non deve richiedere modifiche allo schema.

---

# 10. TEAM REGISTRY

## 10.1 Identità

Il Team FantaGol è interno e indipendente.

## 10.2 Alias

```text
team_alias
- team_id
- locale
- alias
- alias_type
```

## 10.3 Provider mapping

```text
provider_entity_map
- provider_id
- entity_type = team
- internal_id
- external_id
```

## 10.4 Asset

Gli stemmi devono provenire da:

- licenza valida;
- asset creati internamente;
- risorse liberamente riutilizzabili;
- accordi specifici.

Il Competition Engine conserva solo il riferimento.

---

# 11. PROVIDER INTEGRATION CONTRACT

## 11.1 Input normalizzato

Il Provider Engine deve fornire:

```text
NormalizedCompetition
NormalizedEdition
NormalizedStage
NormalizedTeam
NormalizedProviderRound
NormalizedMatch
```

## 11.2 Competition Engine non conosce il payload grezzo

Il parsing appartiene al Provider Adapter.

## 11.3 Conflitti

Se due provider differiscono:

```text
provider conflict
→ log
→ confidence policy
→ provider priority
→ optional admin review
```

## 11.4 Provider priority MVP

```text
primary_calendar_provider
primary_live_provider
fallback_provider
```

Configurazione, non codice hardcoded.

---

# 12. READ MODELS

## 12.1 active_competitions_view

Mostra competizioni disponibili.

## 12.2 competition_edition_overview_view

Mostra edition, stage e stato.

## 12.3 current_fantagol_round_view

Mostra round corrente e lifecycle.

## 12.4 round_match_set_view

Mostra Match Set ordinato.

## 12.5 upcoming_matches_view

Mostra partite future.

## 12.6 competition_calendar_view

Mostra calendario completo.

---

# 13. SECURITY MODEL

## 13.1 Lettura pubblica

Pubblicabili:

- competizioni attive;
- team;
- calendario;
- risultati reali;
- round pubblici.

## 13.2 Scrittura

Solo:

- service role;
- admin autorizzato;
- worker provider;
- RPC controllate.

## 13.3 Admin actions

Ogni azione amministrativa richiede:

- autenticazione;
- ruolo;
- audit;
- reason;
- correlation_id.

## 13.4 RLS

Tutte le nuove tabelle pubbliche devono avere RLS attiva.

---

# 14. IDEMPOTENZA E CONCORRENZA

## 14.1 Comandi idempotenti

```text
ImportMatch
UpdateMatch
CreateFantaGolRound
ApproveMatchSet
OpenRound
LockRound
```

## 14.2 Unique constraints

- competition code;
- edition label per competition;
- stage code per edition;
- provider external ID;
- match identity mapping;
- round sequence per edition;
- slot per round;
- match per round.

## 14.3 Optimistic locking

Entità critiche:

```text
version
updated_at
```

---

# 15. AUDIT

## 15.1 Eventi da auditare

- creazione competizione;
- attivazione/disattivazione;
- import match;
- cambio kickoff;
- sostituzione match;
- approvazione Match Set;
- lock manuale;
- cancellazione round.

## 15.2 Campi minimi

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

---

# 16. OBSERVABILITY

## 16.1 Metriche

```text
competition_sync_total
competition_sync_failed
matches_imported_total
matches_updated_total
rounds_created_total
round_validation_failed_total
round_lock_latency
provider_conflicts_total
```

## 16.2 Health

```text
competition_registry_health
provider_sync_health
round_scheduler_health
match_update_health
```

---

# 17. MIGRATION STRATEGY

## 17.1 Non distruttiva

La prima migrazione deve:

- preservare `seasons`;
- preservare `matchdays`;
- preservare `teams`;
- preservare `matches`;
- creare nuove entità universali;
- introdurre mapping progressivi;
- evitare rename distruttivi immediati.

## 17.2 Compatibilità

Fase transitoria:

```text
legacy seasons/matchdays
+
new competition model
```

## 17.3 Cutover

Solo dopo:

- migrazione dati;
- test;
- verifica RPC;
- doppia lettura;
- confronto risultati.

---

# 18. MVP SERIE A

## 18.1 Seed iniziale

```text
sport = football
competition = Serie A
edition = 2026/27
stage = regular_season
teams = 20
provider rounds = 38
fantagol rounds = 38
matches per round = 10
```

## 18.2 Regole round

```text
selection_policy = official_matchweek
lock_at = kickoff prima partita
match_count = 10
```

## 18.3 Capability

```text
points_pure = true
fantacalcio = true
one_to_one = true
```

---

# 19. TEST PLAN MINIMO

## 19.1 Unit tests

- create competition;
- create edition;
- validate stage sequence;
- register team;
- import match;
- detect duplicate match;
- create round;
- validate 10 match;
- reject 9 match Serie A;
- reject duplicate slot;
- compute lock;
- freeze Match Set.

## 19.2 Integration tests

- provider calendar → normalized data → database;
- provider round → FantaGol Round;
- kickoff change before lock;
- postponed match after lock;
- round open/lock scheduler;
- public read model.

## 19.3 Regression tests

- existing login;
- existing leagues;
- existing club profile;
- existing predictions;
- existing static pages.

---

# 20. ACCEPTANCE CRITERIA

Il Competition Engine v1 è accettato quando:

1. Serie A 2026/27 è rappresentata come Competition Edition.
2. Le 20 squadre sono interne e mappabili ai provider.
3. Le partite sono indipendenti dal provider.
4. Ogni giornata Serie A genera un FantaGol Round da 10 match.
5. Il Match Set è ordinato e versionato.
6. Il lock è calcolato dal primo kickoff.
7. Rinvii e cambi kickoff sono gestiti senza corrompere il round.
8. Il sistema espone capability per le tre modalità.
9. Tutte le scritture critiche sono idempotenti.
10. Nessuna tabella è specifica della Serie A.
11. L'aggiunta futura di Premier League non richiede migrazione strutturale.
12. Le tabelle legacy restano funzionanti durante la transizione.

---

# 21. FILE DI IMPLEMENTAZIONE PREVISTI

```text
docs/engines/competition/FANTAGOL_COMPETITION_ENGINE_MASTER_v1.md
supabase/migrations/002_competition_core.sql
supabase/migrations/002_competition_core_rollback.sql
lib/domain/competition/types.ts
lib/domain/competition/validators.ts
lib/domain/competition/round-builder.ts
lib/domain/competition/errors.ts
lib/domain/competition/events.ts
tests/competition/
```

---

# 22. ORDINE DI IMPLEMENTAZIONE

## Step 1

Congelare il Competition Engine Master.

## Step 2

Disegnare la migrazione non distruttiva.

## Step 3

Creare tipi TypeScript.

## Step 4

Creare validatori puri.

## Step 5

Creare Round Builder deterministico.

## Step 6

Creare RPC amministrative e service-only.

## Step 7

Creare read model.

## Step 8

Seed Serie A.

## Step 9

Test completo.

## Step 10

Esecuzione controllata su Supabase.

---

# 23. DIRETTIVA FINALE

Il Competition Engine deve tradurre il calcio reale nel linguaggio stabile di FantaGol.

Deve essere:

- universale;
- provider-agnostic;
- internazionale;
- deterministico;
- versionato;
- auditabile;
- compatibile con il database esistente;
- semplice da usare per il lancio Serie A;
- pronto per competizioni future senza redesign.
