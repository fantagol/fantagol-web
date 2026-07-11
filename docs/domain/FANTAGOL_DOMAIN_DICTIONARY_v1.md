# FANTAGOL DOMAIN DICTIONARY v1

**Stato:** documento fondativo  
**Ambito:** vocabolario ufficiale del dominio FantaGol  
**Obiettivo:** definire in modo univoco i concetti usati da database, API, RPC, scoring engine, web, Android, documentazione e traduzioni.

---

# 0. REGOLE DEL DIZIONARIO

## 0.1 Un termine, un significato

Ogni termine del dominio deve avere un significato preciso e stabile.

Esempio:

```text
Provider Round ≠ FantaGol Round
Prediction ≠ Strategy
Score Result ≠ Mode Result
Competition ≠ League
```

## 0.2 Lingua tecnica interna

I nomi tecnici ufficiali sono in inglese.

Le interfacce utente possono tradurli.

Esempio:

```text
FantaGol Round
IT: Giornata FantaGol
EN: FantaGol Round
ES: Jornada FantaGol
DE: FantaGol-Spielrunde
FR: Journée FantaGol
```

## 0.3 Nessun termine ambiguo nel codice

Nel codice e nel database evitare nomi generici come:

```text
day
round
game
score
result
table
```

Usare invece:

```text
fantagol_round
provider_round
prediction_score_result
mode_result
standing
```

## 0.4 Autorità del documento

Questo dizionario è la fonte ufficiale per:

- nomi delle entità;
- nomi delle tabelle;
- contratti API;
- tipi TypeScript;
- documentazione;
- chiavi di traduzione;
- naming delle RPC;
- eventi del dominio.

---

# 1. SPORT

## 1.1 Sport

**Definizione:** disciplina sportiva supportata dal motore.

**Esempio iniziale:**

```text
football
```

**Responsabilità:**

- raggruppare competizioni;
- definire regole generali dello sport;
- consentire future estensioni.

**Non significa:**

- competizione;
- stagione;
- torneo.

**Relazioni:**

```text
Sport
  └── Competition
```

---

# 2. COMPETIZIONI REALI

## 2.1 Competition

**Definizione:** competizione calcistica reale organizzata da una lega, federazione o confederazione.

**Esempi:**

- Serie A;
- Premier League;
- Champions League;
- World Cup;
- Euro;
- Copa América.

**Responsabilità:**

- identificare il torneo reale;
- raggruppare edizioni;
- definire tipo e ambito.

**Non significa:**

- lega privata FantaGol;
- singola stagione;
- round FantaGol.

**Relazioni:**

```text
Sport
  └── Competition
        └── Competition Edition
```

## 2.2 Competition Type

**Definizione:** classificazione strutturale della competizione.

**Valori iniziali:**

```text
league
domestic_cup
continental_club
national_team_tournament
qualifier
super_cup
friendly_tournament
```

## 2.3 Competition Scope

**Definizione:** estensione geografica della competizione.

**Valori iniziali:**

```text
domestic
continental
international
```

## 2.4 Competition Edition

**Definizione:** specifica stagione o edizione di una Competition.

**Esempi:**

```text
Serie A 2026/27
Champions League 2026/27
World Cup 2026
Euro 2028
```

**Responsabilità:**

- contenere date e stato;
- raggruppare stage, provider round e match;
- collegare le leghe FantaGol alla competizione scelta.

**Non significa:**

- round;
- fase;
- stagione FantaGol separata.

## 2.5 Competition Stage

**Definizione:** fase interna di una Competition Edition.

**Esempi:**

```text
regular_season
league_phase
group_stage
round_of_16
quarter_final
semi_final
final
```

**Responsabilità:**

- ordinare le fasi;
- distinguere gironi, playoff ed eliminazione diretta;
- aiutare la composizione dei FantaGol Round.

**Non significa:**

- turno del provider;
- giornata di gioco FantaGol.

---

# 3. PROVIDER E DATI ESTERNI

## 3.1 Provider

**Definizione:** servizio esterno che fornisce dati.

**Categorie:**

```text
calendar
live_score
odds
notification
payment
advertising
```

**Responsabilità:**

- fornire dati esterni;
- essere sostituibile;
- non definire le regole del dominio.

**Non significa:**

- fonte autorevole interna;
- database FantaGol;
- motore di gioco.

## 3.2 Provider Adapter

**Definizione:** componente che converte il formato del provider nel formato interno FantaGol.

**Responsabilità:**

- normalizzare dati;
- gestire errori;
- tradurre stati e identificativi;
- isolare il dominio dal provider.

## 3.3 Provider Entity Map

**Definizione:** relazione tra ID esterno e ID interno.

**Esempio:**

```text
provider = api_football
entity_type = match
external_id = 123456
internal_id = uuid
```

**Responsabilità:**

- preservare identità interne stabili;
- supportare più provider;
- evitare dipendenza da ID esterni.

## 3.4 Provider Round

**Definizione:** turno o raggruppamento così come restituito dal provider.

**Esempi:**

```text
Serie A Matchday 3
Champions League League Phase Round 2
World Cup Group Stage Round 1
```

**Responsabilità:**

- conservare il dato sorgente;
- collegare match provenienti dal provider.

**Non significa:**

- set ufficiale di gioco FantaGol;
- giornata della lega privata.

## 3.5 Source Data Version

**Definizione:** identificativo della versione dei dati esterni usata in un calcolo.

**Responsabilità:**

- rendere i calcoli riproducibili;
- supportare audit e ricalcoli.

---

# 4. PARTECIPANTI REALI

## 4.1 Team

**Definizione:** squadra reale partecipante a una competizione.

**Può essere:**

```text
club
national_team
```

**Esempi:**

```text
Inter
Liverpool
Real Madrid
Italy
Argentina
France
```

**Responsabilità:**

- partecipare ai match;
- essere collegata a competizioni ed edizioni.

**Non significa:**

- Club FantaGol dell'utente;
- membro di lega.

## 4.2 Team Type

**Valori:**

```text
club
national_team
```

## 4.3 Club FantaGol

**Definizione:** identità personalizzata dell'utente dentro FantaGol.

**Contiene:**

- nome;
- stemma;
- kit;
- colori;
- motto;
- storico titoli.

**Non significa:**

- squadra reale;
- account utente;
- membership di lega.

## 4.4 User

**Definizione:** account autenticato.

**Responsabilità:**

- possedere un profilo;
- partecipare a leghe;
- possedere un Club FantaGol;
- inserire pronostici e strategie.

## 4.5 Profile

**Definizione:** dati generali dell'utente.

**Contiene:**

- email;
- avatar;
- lingua;
- timezone;
- lega attiva.

---

# 5. MATCH E STATI REALI

## 5.1 Match

**Definizione:** partita calcistica reale tra due Team.

**Responsabilità:**

- contenere kickoff;
- stato;
- risultato;
- collegamenti a edition, stage e provider round.

**Non significa:**

- incontro tra utenti;
- mini-sfida One To One.

## 5.2 Match Status

**Valori minimi:**

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

## 5.3 Match Result

**Definizione:** risultato reale del Match.

**Contiene:**

```text
home_score
away_score
status
finalised_at
```

## 5.4 Match Event

**Definizione:** variazione significativa di stato o risultato.

**Esempi:**

- kickoff;
- score_change;
- halftime;
- fulltime;
- postponed;
- cancelled.

**Non significa:**

- ogni polling del provider.

---

# 6. FANTAGOL ROUND

## 6.1 FantaGol Round

**Definizione:** unità ufficiale di gioco di FantaGol.

**Responsabilità:**

- contenere il set di match validi;
- definire apertura e blocco;
- alimentare pronostici, strategie, scoring e classifiche.

**Non significa:**

- provider round;
- singolo match;
- giornata di una lega privata separata.

## 6.2 FantaGol Round Match

**Definizione:** relazione tra un FantaGol Round e un Match.

**Contiene:**

```text
fantagol_round_id
match_id
slot_number
selection_reason
required
```

## 6.3 Match Set

**Definizione:** insieme ordinato dei match inclusi nel FantaGol Round.

**Responsabilità:**

- essere immutabile dopo il lock;
- definire l'ordine degli slot;
- stabilire i requisiti delle modalità.

## 6.4 Selection Policy

**Definizione:** regola usata per comporre il Match Set.

**Valori iniziali:**

```text
official_matchweek
chronological_first_n
chronological_window
provider_group
manual_admin
balanced_stage
custom_curated
```

## 6.5 Round Lock

**Definizione:** momento oltre il quale pronostici e strategie non sono più modificabili.

**Default:**

```text
kickoff della prima partita
```

## 6.6 Round Status

**Valori:**

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

---

# 7. LEGA FANTAGOL

## 7.1 League

**Definizione:** competizione privata o pubblica tra utenti FantaGol.

**Responsabilità:**

- raggruppare membri;
- collegarsi a una Competition Edition;
- abilitare modalità;
- produrre classifiche proprie.

**Non significa:**

- competizione reale;
- Competition;
- campionato nazionale.

## 7.2 League Member

**Definizione:** partecipazione di un User a una League.

**Contiene:**

```text
league_id
user_id
club_id
role
status
joined_at
```

## 7.3 League Role

**Valori iniziali:**

```text
owner
admin
member
```

## 7.4 League Mode

**Definizione:** configurazione di una modalità dentro una League.

**Contiene:**

```text
mode
enabled
ruleset_version
settings_json
```

## 7.5 League Fixture

**Definizione:** incontro interno tra due League Member.

**Usato da:**

- Fantacalcio;
- One To One.

**Non significa:**

- match reale.

---

# 8. PRONOSTICI

## 8.1 Prediction

**Definizione:** previsione dell'utente sul risultato esatto di un Match.

**Contiene:**

```text
predicted_home_score
predicted_away_score
```

**Responsabilità:**

- essere la fonte unica per tutte le modalità;
- produrre derivazioni automatiche.

**Non significa:**

- strategia;
- punteggio;
- mini-sfida.

## 8.2 Prediction Draft

**Definizione:** pronostico salvato ma non ancora considerato definitivo.

## 8.3 Prediction Submission

**Definizione:** azione con cui l'utente conferma il pronostico.

## 8.4 Prediction Lock

**Definizione:** stato in cui il pronostico non è più modificabile.

## 8.5 Prediction Snapshot

**Definizione:** versione immutabile del pronostico usata nel calcolo.

**Responsabilità:**

- assicurare riproducibilità;
- proteggere lo storico.

## 8.6 Missing Prediction

**Definizione:** assenza di pronostico per un Match.

**Regola ufficiale:**

```text
score = 0
nessun malus
```

## 8.7 Predicted Sign

**Valori:**

```text
1
X
2
```

## 8.8 Predicted Over/Under

**Valori:**

```text
over_2_5
under_2_5
```

## 8.9 Predicted Goal/No Goal

**Valori:**

```text
goal
no_goal
```

---

# 9. SCORING

## 9.1 Scoring Engine

**Definizione:** motore che confronta Prediction Snapshot e Match Result.

**Responsabilità:**

- calcolare componenti base;
- bonus;
- malus;
- output deterministico;
- versionamento.

**Non significa:**

- motore di modalità;
- classifica.

## 9.2 Score Component

**Valori iniziali:**

```text
exact
sign
over_under
goal_no_goal
surprise
gol_show
grand_slam
opposite_sign
cantonata
```

## 9.3 Prediction Score Result

**Definizione:** output completo del calcolo di un singolo pronostico.

**Contiene:**

```text
component points
base_total
scoring_version
provisional
calculated_at
```

**Non significa:**

- totale giornata;
- risultato Fantacalcio;
- mini-sfida One To One.

## 9.4 Base Score

**Definizione:** somma dei componenti del Prediction Score Result prima dei modificatori strategici.

## 9.5 Provisional Score

**Definizione:** punteggio calcolato durante il live.

## 9.6 Official Score

**Definizione:** punteggio ufficializzato dopo la conclusione e validazione del round.

## 9.7 Recalculated Score

**Definizione:** punteggio prodotto da un ricalcolo esplicito.

---

# 10. ODDS E BONUS SORPRESA

## 10.1 Odds Snapshot

**Definizione:** rilevazione delle quote di un bookmaker in un momento preciso.

## 10.2 Aggregated Odds Snapshot

**Definizione:** aggregazione normalizzata di più bookmaker e provider.

## 10.3 Implied Probability

**Definizione:** probabilità derivata dalla quota decimale.

```text
1 / quota
```

## 10.4 Normalised Probability

**Definizione:** probabilità implicita corretta per il margine del bookmaker.

## 10.5 Surprise Outcome

**Definizione:** esito classificato come sorpresa secondo la Odds Policy attiva.

## 10.6 Odds Policy

**Definizione:** versione delle regole usate per determinare il Bonus Sorpresa.

---

# 11. STRATEGIA

## 11.1 Strategy

**Definizione:** scelta dell'utente su come utilizzare i propri pronostici in una modalità.

**Responsabilità:**

- essere separata dal Prediction;
- modificare l'uso dei punti;
- restare nascosta fino al lock.

## 11.2 Strategic Allocation Engine

**Definizione:** motore che valida e applica le strategie.

## 11.3 Attack

**Definizione:** reparto Fantacalcio ad alto rischio e alto rendimento.

**Regola ufficiale:**

```text
5 prediction
```

**Modificatori:**

```text
Exact x2
Bonus Sorpresa x2
Segno Opposto x2
Cantonata x2
```

## 11.4 Defense

**Definizione:** reparto Fantacalcio orientato alla protezione.

**Regola ufficiale:**

```text
5 prediction
```

**Modificatori:**

```text
Segno Opposto x0.5
Cantonata x0.5
```

## 11.5 Fantacalcio Allocation

**Definizione:** assegnazione completa dei 10 pronostici tra Attack e Defense.

## 11.6 Matrix

**Definizione:** insieme ordinato di 10 accoppiamenti One To One scelti da un utente.

## 11.7 Matrix Owner

**Definizione:** utente che decide gli accoppiamenti della matrice.

## 11.8 Pairing

**Definizione:** accoppiamento tra un pronostico proprio e uno avversario.

## 11.9 Mini Challenge

**Definizione:** confronto tra due Prediction Score Result all'interno di una matrice One To One.

**Output:**

```text
win
draw
loss
```

## 11.10 Matrix Result

**Definizione:** risultato aggregato delle 10 Mini Challenge di una matrice.

## 11.11 One To One Aggregate Result

**Definizione:** risultato complessivo delle due matrici indipendenti.

---

# 12. MODALITÀ

## 12.1 Game Mode

**Definizione:** sistema competitivo che usa gli output del motore base.

**Modalità ufficiali:**

```text
points_pure
fantacalcio
one_to_one
```

## 12.2 Points Pure

**Definizione:** modalità basata sulla somma dei Base Score.

## 12.3 Fantacalcio

**Definizione:** modalità H2H che applica Attack/Defense e converte i punti in gol.

## 12.4 One To One

**Definizione:** modalità H2H basata su due matrici indipendenti di Mini Challenge.

## 12.5 Mode Result

**Definizione:** risultato prodotto da una modalità per un utente o un fixture.

**Non significa:**

- Prediction Score Result;
- Standing.

## 12.6 Mode Ruleset

**Definizione:** insieme versionato delle regole di una modalità.

---

# 13. RISULTATI E CLASSIFICHE

## 13.1 Round User Score

**Definizione:** totale di un utente in un FantaGol Round.

## 13.2 Fixture Result

**Definizione:** risultato finale di un League Fixture.

## 13.3 Standing

**Definizione:** posizione aggiornata di un utente nella classifica di una modalità.

## 13.4 Standing Entry

**Definizione:** riga di classifica relativa a un singolo utente.

## 13.5 Competition Points

**Definizione:** punti di classifica H2H.

**Esempio futuro:**

```text
win = 3
draw = 1
loss = 0
```

## 13.6 Raw FantaGol Points

**Definizione:** punti complessivi prodotti dal motore FantaGol.

## 13.7 Tiebreaker

**Definizione:** criterio usato per risolvere una parità in classifica.

## 13.8 Standing Snapshot

**Definizione:** fotografia immutabile della classifica in un momento specifico.

---

# 14. CALCOLO E AUDIT

## 14.1 Calculation Run

**Definizione:** esecuzione tracciata del motore di calcolo.

**Tipi:**

```text
live_partial
final
postponed_recovery
manual_recalculation
manual_correction
```

## 14.2 Calculation Status

**Valori:**

```text
pending
running
completed
failed
cancelled
```

## 14.3 Ruleset Version

**Definizione:** versione delle regole usate nel calcolo.

## 14.4 Audit Log

**Definizione:** registro immutabile delle azioni amministrative e dei ricalcoli.

## 14.5 Manual Correction

**Definizione:** correzione esplicita applicata da un amministratore autorizzato.

## 14.6 Recalculation

**Definizione:** nuova esecuzione del calcolo su dati o regole specificati.

---

# 15. LIVE

## 15.1 Live Engine

**Definizione:** sistema che acquisisce, normalizza e distribuisce aggiornamenti live.

## 15.2 Polling

**Definizione:** interrogazione periodica del provider.

## 15.3 Adaptive Polling

**Definizione:** frequenza variabile in base allo stato dei match.

## 15.4 Live Snapshot

**Definizione:** stato corrente di match e punteggi durante il live.

## 15.5 Realtime Delivery

**Definizione:** distribuzione degli aggiornamenti ai client web e Android.

## 15.6 Idempotency

**Definizione:** proprietà per cui lo stesso aggiornamento ripetuto non produce duplicazioni.

---

# 16. CONTROL ROOM

## 16.1 Control Room

**Definizione:** area premium di statistiche e analisi.

**Responsabilità:**

- leggere risultati già calcolati;
- mostrare dati aggregati;
- non modificare il gioco.

## 16.2 Control Room Scope

**Valori:**

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

## 16.3 Control Room Access Session

**Definizione:** finestra temporale durante la quale l'utente può accedere alla Control Room.

## 16.4 Statistic Aggregate

**Definizione:** dato statistico aggregato e non identificativo.

## 16.5 Historical Archive

**Definizione:** archivio consultabile di round, pronostici, risultati e statistiche passate.

---

# 17. PASS E MONETIZZAZIONE

## 17.1 Pass

**Definizione:** unità digitale usata per sbloccare una sessione Control Room.

## 17.2 Pass Wallet

**Definizione:** saldo Pass dell'utente.

## 17.3 Pass Transaction

**Definizione:** movimento del saldo Pass.

## 17.4 Pass Source

**Valori:**

```text
purchase
rewarded_ad
league_prize
exact_reward
gift
promotion
admin_adjustment
```

## 17.5 Pass Gift

**Definizione:** trasferimento di Pass tra utenti secondo regole definite.

## 17.6 Rewarded Ad

**Definizione:** pubblicità video che assegna Pass come ricompensa.

## 17.7 Purchase

**Definizione:** acquisto di un pacchetto Pass.

## 17.8 Donation

**Definizione:** contributo volontario senza vantaggio competitivo.

## 17.9 Pay-to-Win

**Definizione:** qualsiasi monetizzazione che altera punti, pronostici o classifiche.

**Regola ufficiale:**

```text
vietato
```

---

# 18. INTERNAZIONALIZZAZIONE

## 18.1 Locale

**Definizione:** combinazione di lingua e convenzioni regionali.

**Esempi:**

```text
it-IT
en-GB
es-ES
de-DE
fr-FR
```

## 18.2 Translation Key

**Definizione:** identificativo stabile di un testo traducibile.

**Esempio:**

```text
round.status.predictions_open
```

## 18.3 Timezone

**Definizione:** fuso orario usato per visualizzare date e orari.

## 18.4 UTC Timestamp

**Definizione:** formato temporale canonico salvato nel database.

## 18.5 Regulation Version

**Definizione:** versione ufficiale e traducibile del regolamento.

---

# 19. SICUREZZA

## 19.1 Authenticated User

**Definizione:** utente con sessione valida.

## 19.2 Anonymous User

**Definizione:** visitatore non autenticato.

## 19.3 Service Role

**Definizione:** ruolo server privilegiato non esposto ai client.

## 19.4 Row Level Security

**Definizione:** controllo di accesso a livello di riga PostgreSQL.

## 19.5 Security Definer RPC

**Definizione:** funzione eseguita con privilegi del proprietario e validazioni interne obbligatorie.

## 19.6 Hidden Strategy

**Definizione:** strategia non leggibile dagli avversari prima del lock.

## 19.7 Private Prediction

**Definizione:** pronostico non leggibile dagli altri utenti prima del momento consentito.

---

# 20. EVENTI DI DOMINIO

## 20.1 Domain Event

**Definizione:** fatto significativo avvenuto nel sistema.

## 20.2 Eventi iniziali

```text
competition_edition_created
fantagol_round_created
match_set_approved
predictions_opened
prediction_saved
prediction_submitted
strategy_submitted
round_locked
match_started
match_score_changed
match_finished
provisional_score_calculated
round_finalised
standings_updated
pass_purchased
pass_rewarded
control_room_access_started
```

---

# 21. TERMINI VIETATI O SCONSIGLIATI

## 21.1 "Giornata"

Usare solo nella UI italiana.

Nel dominio tecnico usare:

```text
fantagol_round
provider_round
```

## 21.2 "Partita"

Nel dominio tecnico distinguere:

```text
match
league_fixture
mini_challenge
```

## 21.3 "Punteggio"

Distinguere:

```text
prediction_score_result
round_user_score
mode_result
competition_points
```

## 21.4 "Squadra"

Distinguere:

```text
team
club_fantagol
league_member
```

## 21.5 "Campionato"

Distinguere:

```text
competition
competition_edition
league
```

---

# 22. MAPPATURA TERMINI UI ITALIANI

| Dominio tecnico | UI italiana |
|---|---|
| Competition | Competizione |
| Competition Edition | Stagione / Edizione |
| Competition Stage | Fase |
| Provider Round | Turno ufficiale |
| FantaGol Round | Giornata FantaGol |
| Match | Partita |
| League | Lega |
| League Fixture | Sfida di giornata |
| Prediction | Pronostico |
| Prediction Snapshot | Pronostico bloccato |
| Attack | Attacco |
| Defense | Difesa |
| Matrix | Matrice |
| Pairing | Accoppiamento |
| Mini Challenge | Mini-sfida |
| Prediction Score Result | Punteggio pronostico |
| Round User Score | Punteggio giornata |
| Mode Result | Risultato modalità |
| Standing | Classifica |
| Pass | Pass |
| Control Room Access Session | Accesso Control Room |

---

# 23. INVARIANTI LINGUISTICHE

1. `Competition` indica sempre una competizione reale.
2. `League` indica sempre una lega FantaGol.
3. `Match` indica sempre una partita reale.
4. `League Fixture` indica sempre una sfida tra utenti.
5. `Prediction` indica sempre la previsione del risultato.
6. `Strategy` indica sempre l'uso del pronostico.
7. `Prediction Score Result` indica sempre il punteggio base.
8. `Mode Result` indica sempre l'output di una modalità.
9. `Standing` indica sempre la classifica.
10. `Provider Round` e `FantaGol Round` non sono sinonimi.
11. `Team` e `Club FantaGol` non sono sinonimi.
12. `Pass` non è un punto di gioco.
13. `Control Room` non modifica mai il risultato.
14. Le traduzioni non cambiano il significato tecnico.
15. I nomi tecnici restano stabili anche se la UI cambia.

---

# 24. DIRETTIVA FINALE

Ogni nuova entità, tabella, RPC, endpoint, tipo TypeScript o componente di dominio deve usare i termini definiti in questo documento.

Quando emerge un nuovo concetto:

```text
idea
→ definizione nel Domain Dictionary
→ approvazione
→ database
→ API
→ codice
→ UI
```

Nessun nuovo termine deve essere introdotto nel codice senza una definizione esplicita e coerente con il modello FantaGol.
