# FANTAGOL GAME ENGINE MASTER v1

**Stato:** documento fondativo  
**Ambito:** motore di gioco indipendente da web, Android, provider e singola competizione  
**Obiettivo:** definire il funzionamento universale di FantaGol per competizioni di club e nazionali, nazionali e internazionali, a gironi o a eliminazione diretta.

---

# 0. PRINCIPI FONDATIVI

## 0.1 FantaGol non dipende dalla Serie A

FantaGol deve poter funzionare con qualsiasi competizione calcistica che disponga di:

- calendario affidabile;
- partite programmate;
- risultati disponibili;
- un numero sufficiente di incontri;
- una struttura temporale utile alla creazione di round di gioco.

Esempi supportabili:

- Serie A;
- Premier League;
- Liga;
- Bundesliga;
- Ligue 1;
- Champions League;
- Europa League;
- Conference League;
- Mondiali;
- Europei;
- Copa América;
- Nations League;
- qualificazioni mondiali ed europee;
- tornei futuri equivalenti.

## 0.2 La competizione reale non coincide con il round FantaGol

La competizione reale fornisce le partite.

FantaGol decide come raggrupparle in un set di gioco coerente.

```text
COMPETIZIONE REALE
        ↓
ROUND DEL PROVIDER
        ↓
SELEZIONE FANTAGOL
        ↓
FANTAGOL ROUND
        ↓
PRONOSTICI
        ↓
STRATEGIA
        ↓
CALCOLO
        ↓
MODALITÀ
        ↓
CLASSIFICHE
```

## 0.3 Un solo pronostico alimenta tutte le modalità

L'utente inserisce una sola previsione per ogni partita.

Lo stesso pronostico alimenta:

- Punti Puri;
- Fantacalcio;
- One To One;
- statistiche;
- Control Room;
- storico;
- Hall of Fame.

## 0.4 Pronostico, strategia e risultato sono entità separate

Il sistema deve distinguere sempre:

1. **Pronostico** — previsione dell'utente.
2. **Strategia** — uso del pronostico nelle modalità.
3. **Scoring Result** — punti prodotti dal motore.
4. **Mode Result** — trasformazione dei punti nella modalità.
5. **Standing Result** — effetto sulla classifica.

Nessuna modalità deve ricalcolare direttamente il punteggio base.

---

# 1. MODELLO UNIVERSALE DELLE COMPETIZIONI

## 1.1 Sport

Entità radice, predisposta per eventuale espansione futura.

```text
sport
- id
- code
- name_key
- active
```

Per il lancio:

```text
code = football
```

## 1.2 Competition

Rappresenta una competizione reale.

```text
competition
- id
- sport_id
- provider_key
- code
- name_key
- country_code nullable
- confederation_code nullable
- competition_type
- scope
- active
```

Valori suggeriti:

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
```

## 1.3 Edition

Rappresenta una specifica stagione o edizione.

```text
competition_edition
- id
- competition_id
- label
- year_start
- year_end
- start_at
- end_at
- status
```

Esempi:

```text
Serie A 2026/27
Champions League 2026/27
World Cup 2026
Euro 2028
```

## 1.4 Stage

Rappresenta una fase interna della competizione.

```text
competition_stage
- id
- edition_id
- code
- name_key
- stage_type
- sequence
- starts_at
- ends_at
```

Valori possibili:

```text
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
```

## 1.5 Provider Round

Rappresenta il turno così come fornito dalla fonte dati.

```text
provider_round
- id
- provider_id
- edition_id
- stage_id
- external_id
- name
- number nullable
- starts_at
- ends_at
```

Il provider round è un dato sorgente e non determina automaticamente il set di gioco FantaGol.

## 1.6 Match

Rappresenta una partita reale.

```text
match
- id
- edition_id
- stage_id
- provider_round_id nullable
- home_team_id
- away_team_id
- kickoff_at
- status
- home_score nullable
- away_score nullable
- provider_updated_at nullable
- finalised_at nullable
```

Stati minimi:

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

---

# 2. FANTAGOL ROUND

## 2.1 Definizione

Il FantaGol Round è l'unità di gioco ufficiale.

Contiene il set di partite sul quale gli utenti inseriscono pronostici e strategie.

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
```

## 2.2 Stati

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

## 2.3 Composizione

La relazione tra FantaGol Round e partite è esplicita.

```text
fantagol_round_match
- fantagol_round_id
- match_id
- slot_number
- selection_reason
- source_round_id nullable
- required
```

Vincoli:

- una partita non può comparire due volte nello stesso round;
- `slot_number` è univoco per round;
- l'ordine è stabile dopo il blocco;
- la composizione ufficiale è versionata.

## 2.4 Politiche di selezione

```text
official_matchweek
chronological_first_n
chronological_window
provider_group
manual_admin
balanced_stage
custom_curated
```

## 2.5 Requisiti per modalità

### Punti Puri

Può funzionare con numero variabile di partite.

```text
minimum_match_count >= 1
```

### Fantacalcio

Versione ufficiale corrente:

```text
required_match_count = 10
attack_slots = 5
defense_slots = 5
```

### One To One

Versione ufficiale corrente:

```text
required_match_count = 10
matrix_count = 2
pairings_per_matrix = 10
```

Se un round contiene meno di 10 partite:

- Punti Puri può restare attivo;
- Fantacalcio e One To One devono risultare disattivati o usare una futura variante esplicitamente configurata;
- il sistema non deve improvvisare regole automatiche.

---

# 3. CICLO DI VITA DI UNA GIORNATA

```text
DRAFT
  ↓
MATCH SET APPROVED
  ↓
PREDICTIONS OPEN
  ↓
USER SAVES DRAFTS
  ↓
USER SUBMITS
  ↓
STRATEGIES SUBMITTED
  ↓
LOCK
  ↓
LIVE DATA INGESTION
  ↓
PROVISIONAL SCORING
  ↓
MODE CALCULATION
  ↓
PARTIAL RESULTS
  ↓
FINAL DATA
  ↓
OFFICIAL SCORING
  ↓
STANDINGS UPDATE
  ↓
ARCHIVE
```

## 3.1 Apertura

Requisiti:

- round esistente;
- set partite approvato;
- orari disponibili;
- modalità abilitate;
- quote disponibili o fallback definito per Bonus Sorpresa.

## 3.2 Blocco

Il blocco è centralizzato a livello round.

Default:

```text
lock_at = kickoff della prima partita
```

Possibili configurazioni future:

```text
lock_offset_minutes
per_match_lock
admin_manual_lock
```

La versione ufficiale iniziale usa il blocco unico del round.

## 3.3 Live

Durante il live:

- i risultati sono provvisori;
- il punteggio viene ricalcolato solo quando cambia un risultato o uno stato rilevante;
- le classifiche live non sostituiscono quelle ufficiali;
- ogni dato mostra chiaramente lo stato `provisional`.

## 3.4 Ufficializzazione

Un round diventa ufficiale quando:

- tutte le partite richieste sono concluse;
- eventuali rinvii sono risolti secondo policy;
- lo snapshot quote ufficiale è valido;
- il calcolo è completato;
- non vi sono errori bloccanti.

---

# 4. PREDICTION ENGINE

## 4.1 Pronostico base

```text
prediction
- id
- league_id
- fantagol_round_id
- match_id
- user_id
- predicted_home_score
- predicted_away_score
- status
- submitted_at
- locked_at nullable
- version
```

Stati:

```text
draft
submitted
locked
void
```

Vincoli:

- un solo pronostico per utente, lega e partita;
- valori interi non negativi;
- modifica consentita solo prima del blocco;
- assenza pronostico = 0 punti;
- nessun malus per mancato inserimento.

## 4.2 Derivazioni automatiche

Dal risultato esatto pronosticato si derivano:

```text
predicted_sign
predicted_over_under_2_5
predicted_goal_no_goal
predicted_total_goals
```

L'utente non inserisce separatamente questi valori.

## 4.3 Snapshot immutabile

Al blocco, il sistema crea o conferma una versione immutabile del pronostico usata dal calcolo ufficiale.

Le modifiche successive richiedono:

- procedura amministrativa;
- audit log;
- ricalcolo esplicito.

---

# 5. ODDS ENGINE E BONUS SORPRESA

## 5.1 Obiettivo

Determinare gli esiti Sorpresa usando una media robusta delle probabilità implicite provenienti da più bookmaker e, preferibilmente, più provider.

## 5.2 Raccolta

```text
odds_snapshot
- match_id
- provider_id
- bookmaker_id
- market
- outcome
- decimal_odds
- collected_at
- snapshot_type
```

Mercato iniziale:

```text
h2h / 1X2
```

## 5.3 Normalizzazione

Per ogni bookmaker:

```text
raw_probability = 1 / decimal_odds
normalised_probability =
raw_probability / somma_probabilità_1X2
```

## 5.4 Aggregazione

```text
aggregated_odds_snapshot
- match_id
- avg_probability_home
- avg_probability_draw
- avg_probability_away
- providers_count
- bookmakers_count
- dispersion
- official_at
- valid
```

## 5.5 Qualità minima

La policy deve essere configurabile.

Default raccomandato:

```text
minimum_bookmakers = 3
preferred_minimum_providers = 2
```

Se il dato non raggiunge la qualità minima:

- il Bonus Sorpresa non viene assegnato;
- il punteggio base resta valido;
- il round non viene bloccato per questo motivo, salvo scelta amministrativa.

---

# 6. SCORING ENGINE BASE

## 6.1 Pipeline

```text
PREDICTION SNAPSHOT
        ↓
REAL RESULT
        ↓
BASE COMPONENTS
        ↓
BONUS
        ↓
MALUS
        ↓
BASE SCORE RESULT
        ↓
STRATEGIC MODIFIERS
        ↓
MODE INPUT
```

## 6.2 Componenti base

```text
Exact: +6
Segno 1X2: +3
Over/Under 2.5: +1
Goal/No Goal: +1
```

Totale Exact:

```text
6 + 3 + 1 + 1 = 11
```

Massimo senza Exact:

```text
5
```

## 6.3 Bonus

```text
Bonus Sorpresa: +2
Gol Show: +1
Grande Slam: +1
```

Massimo singola partita:

```text
14
```

## 6.4 Malus

```text
Segno Opposto: -1
Cantonata: -2
```

Regola:

- Cantonata e Segno Opposto non sono cumulabili;
- Cantonata prevale quando risultano errati Segno, Over/Under e Goal/No Goal;
- i punteggi negativi sono ammessi.

## 6.5 Output standard

```text
prediction_score_result
- prediction_id
- scoring_version
- exact_points
- sign_points
- over_under_points
- goal_no_goal_points
- surprise_points
- gol_show_points
- grand_slam_points
- opposite_sign_malus
- cantonata_malus
- base_total
- calculated_at
- provisional
```

Questo risultato è unico e condiviso da tutte le modalità.

---

# 7. STRATEGIC ALLOCATION ENGINE

## 7.1 Principio

Le strategie non alterano il pronostico né il suo punteggio base.

Producono un punteggio strategico per la modalità.

```text
BASE SCORE
     ↓
STRATEGIC ALLOCATION
     ↓
MODE SCORE
```

## 7.2 Fantacalcio: Attacco e Difesa

Ogni utente assegna esattamente:

```text
5 pronostici → ATTACK
5 pronostici → DEFENSE
```

Vincoli:

- tutti i 10 pronostici devono essere assegnati;
- nessun pronostico può apparire in entrambi;
- nessuna duplicazione;
- modifica solo prima del blocco;
- strategia completa obbligatoria per l'invio.

### Attacco

Modificatori ufficiali:

```text
Exact: x2
Bonus Sorpresa: x2
Segno Opposto: x2
Cantonata: x2
```

Componenti non modificati:

```text
Segno
Over/Under
Goal/No Goal
Gol Show
Grande Slam
```

Nota: qualsiasi futura modifica ai componenti raddoppiati deve essere versionata, non applicata retroattivamente.

### Difesa

Modificatori ufficiali:

```text
Segno Opposto: x0.5
Cantonata: x0.5
```

Tutti i bonus restano invariati.

Il motore deve supportare valori frazionari senza perdita di precisione.

## 7.3 One To One: matrici indipendenti

Per ogni incontro tra Utente A e Utente B vengono costruite due matrici.

### Matrice A

L'Utente A decide gli accoppiamenti:

```text
A1 vs Bx
A2 vs By
...
A10 vs Bz
```

### Matrice B

L'Utente B decide autonomamente:

```text
B1 vs Ax
B2 vs Ay
...
B10 vs Az
```

Ogni matrice contiene 10 mini-sfide.

Vincoli per ogni matrice:

- ogni pronostico proprio è usato una sola volta;
- ogni pronostico avversario è usato una sola volta;
- nessuna coppia incompleta;
- esattamente 10 accoppiamenti;
- le due matrici sono indipendenti;
- le scelte restano nascoste all'avversario fino al blocco.

## 7.4 Risultato mini-sfida

Confronto tra i punti base dei due pronostici.

```text
maggiore → vittoria mini-sfida
uguale → pareggio mini-sfida
minore → sconfitta mini-sfida
```

La regola deve essere versionata nel caso in cui vengano introdotti futuri spareggi.

## 7.5 Risultato finale One To One

Si sommano i risultati delle 20 mini-sfide complessive.

Output minimo:

```text
mini_wins
mini_draws
mini_losses
```

Il risultato finale dell'incontro deriva dal confronto tra mini-vittorie complessive.

---

# 8. GAME MODES ENGINE

## 8.1 Punti Puri

Input:

```text
somma prediction_score_result.base_total
```

Output:

```text
round_points
cumulative_points
exact_count
bonus_count
malus_count
```

I punteggi negativi riducono il totale.

## 8.2 Fantacalcio

Input:

```text
prediction_score_result
+
fantacalcio strategic allocation
```

Pipeline:

```text
base score
→ modifier per Attack/Defense
→ round strategic total
→ conversione in gol
→ risultato H2H
→ classifica
```

La conversione punti-gol è un profilo versionato e configurabile.

## 8.3 One To One

Input:

```text
prediction_score_result.base_total
+
matrix A
+
matrix B
```

Pipeline:

```text
20 mini-sfide
→ mini results
→ aggregate result
→ classifica H2H
```

## 8.4 Indipendenza delle modalità

Ogni lega può attivare:

- una modalità;
- due modalità;
- tutte e tre.

Le classifiche sono indipendenti.

La disattivazione di una modalità non elimina i pronostici base.

---

# 9. LEAGUE ENGINE

## 9.1 Lega FantaGol

Una lega è un contenitore sociale e competitivo.

```text
league
- id
- edition_id
- name
- owner_id
- invite_code
- status
- locale
- timezone
- created_at
```

## 9.2 Modalità per lega

```text
league_mode
- league_id
- mode
- enabled
- ruleset_version
- settings_json
```

## 9.3 Membri

```text
league_member
- league_id
- user_id
- club_id
- role
- status
- joined_at
```

## 9.4 Calendari interni

Fantacalcio e One To One possono avere calendari H2H interni separati dalla competizione reale.

```text
league_fixture
- league_id
- fantagol_round_id
- mode
- home_member_id
- away_member_id
```

---

# 10. STANDINGS ENGINE

## 10.1 Classifiche indipendenti

Ogni modalità produce una propria classifica.

```text
standing
- league_id
- mode
- user_id
- position
- competition_points
- raw_fantagol_points
- stats_json
- updated_at
```

## 10.2 Spareggi

Gli spareggi devono essere definiti da profilo versionato.

Base comune prevista:

```text
1. Exact
2. Bonus Sorpresa
3. ulteriori criteri configurati
```

Le modalità H2H possono utilizzare criteri aggiuntivi specifici.

## 10.3 Provisional vs Official

Ogni risultato deve esporre:

```text
provisional
official
recalculated
```

Le classifiche ufficiali vengono aggiornate solo dal calcolo finale.

---

# 11. LIVE ENGINE

## 11.1 Principio

I client non chiamano direttamente i provider.

```text
PROVIDER
   ↓
FANTAGOL INGESTION
   ↓
NORMALIZER
   ↓
DATABASE CACHE
   ↓
REALTIME / API FANTAGOL
   ↓
WEB + ANDROID
```

## 11.2 Frequenza

Per FantaGol è sufficiente un aggiornamento tipico tra 30 e 90 secondi.

Il polling deve essere adattivo:

```text
nessuna partita live → frequenza bassa
partite imminenti → frequenza media
partite live → frequenza alta
round concluso → stop polling
```

## 11.3 Eventi persistiti

Non salvare una nuova riga a ogni polling.

Persistire:

- cambi di stato;
- cambi di risultato;
- inizio;
- intervallo;
- fine;
- rinvio;
- annullamento;
- ricalcolo.

## 11.4 Idempotenza

Ogni aggiornamento deve poter essere ripetuto senza duplicare eventi o punteggi.

---

# 12. PROVIDER ABSTRACTION LAYER

## 12.1 Contratti

```text
CompetitionProvider
CalendarProvider
LiveScoreProvider
OddsProvider
NotificationProvider
PaymentProvider
AdvertisingProvider
```

## 12.2 Identità interne

FantaGol mantiene ID propri.

Gli ID esterni vengono memorizzati in mapping separati.

```text
provider_entity_map
- provider_id
- entity_type
- internal_id
- external_id
```

## 12.3 Multi-provider

Il sistema deve poter:

- usare un provider principale;
- usare fallback;
- confrontare dati;
- cambiare provider senza modificare il dominio;
- aggregare quote da più fonti.

---

# 13. INTERNAZIONALIZZAZIONE

## 13.1 Nessun testo di dominio hardcoded

Usare chiavi di traduzione.

```text
round.status.predictions_open
prediction.status.locked
mode.fantacalcio.attack
mode.fantacalcio.defense
mode.onetoone.matrix
```

## 13.2 Lingue iniziali previste

```text
it
en
es
de
fr
```

## 13.3 Localizzazione

Ogni utente e lega devono avere:

```text
locale
timezone
date_format
```

I timestamp restano salvati in UTC.

## 13.4 Regolamento

Il regolamento ufficiale deve essere:

- versionato;
- traducibile;
- collegato al ruleset;
- immutabile per le giornate già concluse.

---

# 14. VERSIONAMENTO DELLE REGOLE

## 14.1 Obbligo

Ogni calcolo deve riportare:

```text
scoring_version
strategy_version
mode_ruleset_version
odds_policy_version
```

## 14.2 Non retroattività

Le nuove regole non modificano automaticamente i risultati storici.

Un ricalcolo storico richiede:

- autorizzazione amministrativa;
- versione esplicita;
- audit log;
- motivazione.

---

# 15. AUDIT E RICALCOLO

## 15.1 Audit minimo

```text
calculation_run
- id
- fantagol_round_id
- league_id
- type
- ruleset_versions
- source_data_version
- triggered_by
- started_at
- completed_at
- status
```

## 15.2 Tipi

```text
live_partial
final
postponed_recovery
manual_recalculation
manual_correction
```

## 15.3 Riproducibilità

Dato lo stesso:

- pronostico bloccato;
- risultato reale;
- snapshot quote;
- ruleset;
- strategia;

il motore deve produrre sempre lo stesso output.

---

# 16. CONTROL ROOM

## 16.1 Origine dati

La Control Room non ricalcola il gioco.

Consuma risultati già prodotti dal motore.

## 16.2 Livelli

```text
league
competition
edition
round
country
global
user
club
```

## 16.3 Statistiche iniziali

```text
prediction_distribution
exact_rate
surprise_rate
average_score
attack_efficiency
defense_efficiency
one_to_one_pairing_efficiency
ranking_trends
```

## 16.4 Privacy

Le statistiche globali devono usare dati aggregati e non esporre pronostici privati prima del blocco.

---

# 17. MONETIZZAZIONE

## 17.1 Pass Control Room

```text
pass_wallet
pass_transaction
control_room_access_session
pass_gift
pass_reward
```

## 17.2 Origine Pass

```text
purchase
rewarded_ad
league_prize
exact_reward
gift
promotion
admin_adjustment
```

## 17.3 Principio

La monetizzazione non altera mai il vantaggio competitivo nel gioco.

I Pass sbloccano:

- accesso;
- statistiche;
- storico;
- approfondimenti.

Non modificano punti, pronostici o classifiche.

---

# 18. SICUREZZA

## 18.1 Client non fidato

Web e Android sono client non fidati.

Operazioni critiche devono passare da:

- RPC validate;
- server functions;
- service role non esposta;
- vincoli database.

## 18.2 Dati nascosti

Prima del blocco:

- pronostici altrui non visibili;
- matrici One To One altrui non visibili;
- strategie Fantacalcio altrui non visibili.

## 18.3 Privilegio minimo

Le RPC pubbliche devono essere eseguibili solo dai ruoli necessari.

---

# 19. INVARIANTI DEL MOTORE

Queste regole non devono mai essere violate:

1. Un pronostico base è unico per utente, lega e partita.
2. Una modalità non ricalcola il punteggio base.
3. Un round ufficiale usa una composizione partite immutabile.
4. Fantacalcio ufficiale richiede 5 Attacco e 5 Difesa.
5. Nessun pronostico Fantacalcio può stare in entrambi i reparti.
6. Ogni matrice One To One usa ciascun pronostico una sola volta per lato.
7. Le due matrici One To One sono indipendenti.
8. Le strategie restano nascoste fino al blocco.
9. Ogni calcolo è versionato.
10. I risultati storici non cambiano senza ricalcolo esplicito.
11. I client non accedono direttamente ai provider.
12. La lingua non modifica la logica.
13. La competizione reale non coincide necessariamente con il round FantaGol.
14. Punti negativi ammessi.
15. Mancato pronostico = 0 punti.
16. Monetizzazione mai pay-to-win.

---

# 20. OUTPUT DEL MOTORE

Per ogni round il motore deve poter produrre:

```text
match results
prediction score results
fantacalcio strategic scores
one to one mini results
points pure totals
fantacalcio fixture results
one to one fixture results
provisional standings
official standings
control room aggregates
audit log
```

---

# 21. SEQUENZA DI IMPLEMENTAZIONE

## Phase A — Competition Core

- competitions;
- editions;
- stages;
- provider rounds;
- provider mappings;
- universal matches.

## Phase B — FantaGol Round Core

- fantagol rounds;
- round-match selection;
- lifecycle;
- lock.

## Phase C — Prediction Engine

- drafts;
- submit;
- lock;
- immutable snapshot.

## Phase D — Odds Engine

- multi-provider collection;
- normalisation;
- official snapshot;
- Bonus Sorpresa.

## Phase E — Scoring Engine

- component calculation;
- bonus/malus;
- versioned results.

## Phase F — Strategy Engine

- Fantacalcio Attacco/Difesa;
- One To One matrices;
- validation.

## Phase G — Mode Engine

- Punti Puri;
- Fantacalcio;
- One To One;
- standings.

## Phase H — Live Engine

- polling;
- normalisation;
- provisional calculation;
- realtime delivery.

## Phase I — Internationalisation

- translation keys;
- locales;
- timezones;
- translated regulation.

## Phase J — Control Room and Monetisation

- analytics;
- Pass;
- access sessions;
- ads;
- purchases.

---

# 22. DECISIONI APERTE DA CONGELARE PRIMA DEL CODICE FINALE

1. Fasce ufficiali punti-gol Fantacalcio.
2. Punteggio classifica H2H.
3. Spareggi specifici Fantacalcio.
4. Spareggi specifici One To One.
5. Policy rinvii.
6. Soglia esatta Bonus Sorpresa.
7. Metodo definitivo per Gol Show.
8. Policy round con meno di 10 partite.
9. Visibilità dei pronostici dopo il blocco.
10. Frequenza e durata accesso Control Room.

---

# 23. DIRETTIVA FINALE

FantaGol deve essere costruito come motore universale di fantasy predictions.

Il dominio non deve dipendere da:

- Serie A;
- lingua italiana;
- singolo provider;
- sito web;
- Android;
- formato campionato;
- presenza di club o nazionali.

Il motore deve ricevere partite, pronostici, strategie, risultati e ruleset versionati, producendo output deterministici riutilizzabili da qualsiasi interfaccia e competizione.
