# FANTAGOL COMMUNITY INTELLIGENCE MASTER v1

**Stato:** documento fondativo operativo  
**Ambito:** analytics globali anonimi e Control Room FantaGol  
**Obiettivo:** trasformare pronostici e strategie aggregate della community in indicatori utili alla decisione, senza sostituire il giocatore, modificare il dominio o esporre dati individuali.

---

# 0. PRINCIPI FONDATIVI

## 0.1 Intelligenza collettiva

Ogni pronostico e ogni strategia contribuiscono alla lettura collettiva della giornata.

La Control Room rende osservabile tale lettura.

## 0.2 Supporto decisionale, non suggerimento

La Control Room non dice cosa giocare.

Mostra:

- cosa sta scegliendo la community;
- quanto è concentrato il consenso;
- come cambia nel tempo;
- quali partite sono considerate più prevedibili;
- come vengono usate nelle strategie.

## 0.3 Dataset globale

Gli analytics della Control Room utilizzano il dataset globale FantaGol.

Non si limitano alla lega dell'utente.

## 0.4 Anonimato

I dati globali sono aggregati.

Non espongono:

- nomi;
- utenti;
- club;
- leghe;
- singoli pronostici;
- singole strategie.

## 0.5 Separazione dalle statistiche di lega

```text
CONTROL ROOM
global
aggregata
anonima
predittiva

LEAGUE STATISTICS
locale
nominativa
storica
sociale
```

## 0.6 Il valore principale è pre-live

La fase pre-live serve a migliorare la costruzione:

- dei pronostici;
- dell'Attacco;
- della Difesa;
- delle matrici One To One.

Live e post-live servono soprattutto a confermare o smentire la lettura collettiva.

---

# 1. ENGINE CONTRACT

## 1.1 Nome

```text
CommunityIntelligenceEngine
```

## 1.2 Artefatto principale

```text
CommunityIntelligenceSnapshot
```

## 1.3 Input

```text
SubmittedPredictionSnapshots
SubmittedStrategySnapshots
MatchSetSnapshot
OddsSnapshot
RoundTimeline
CertifiedResults
```

## 1.4 Output

```text
ConsensusSnapshot
LongTrendSnapshot
SurpriseTrendSnapshot
AttackUsageSnapshot
DefenseUsageSnapshot
OneToOnePairingSnapshot
PredictabilitySnapshot
CommunityIntelligenceSnapshot
```

## 1.5 Comandi

```text
BuildCommunitySnapshot
RefreshCommunitySnapshot
ClosePreLiveSnapshot
BuildPostLiveEvaluation
ArchiveCommunitySnapshot
```

## 1.6 Eventi

```text
CommunitySnapshotBuilt
ConsensusChanged
LongTrendUpdated
SurpriseTrendUpdated
StrategyUsageUpdated
CommunityPredictionEvaluated
```

## 1.7 Query

```text
GetControlRoomOverview
GetMatchCommunityIntelligence
GetRoundLongTrend
GetStrategyIntelligence
GetHistoricalPredictability
```

---

# 2. POSIZIONE NELL'ARCHITETTURA

```text
Prediction Snapshots
Strategy Snapshots
Round Timeline
Certified Results
      │
      ▼
COMMUNITY INTELLIGENCE ENGINE
      │
      ▼
CONTROL ROOM VIEW MODELS
      │
      ▼
Web / Android
```

Il motore legge.

Non modifica:

- pronostici;
- strategie;
- punteggi;
- classifiche;
- ledger.

---

# 3. COMMUNITY INTELLIGENCE SNAPSHOT

## 3.1 Definizione

Fotografia anonima e aggregata della lettura collettiva di una giornata.

## 3.2 Identità

```text
snapshot_id
fantagol_round_id
snapshot_version
phase
generated_at
prediction_count
strategy_count
input_hash
output_hash
```

## 3.3 Fasi

```text
pre_live
lock
live
post_live
historical
```

## 3.4 Immutabilità

Ogni snapshot rappresenta un istante.

Il Long Trend nasce dalla sequenza degli snapshot, non dalla sovrascrittura dello stesso dato.

---

# 4. CONSENSUS

## 4.1 Definizione

Distribuzione delle scelte della community per una partita.

## 4.2 Livelli minimi

### Risultato esatto

```text
exact_score_distribution
```

### Segno

```text
home_win_percent
draw_percent
away_win_percent
```

### Over/Under

```text
over_2_5_percent
under_2_5_percent
```

### Goal/No Goal

```text
goal_percent
no_goal_percent
```

## 4.3 Exact più giocati

Mostrare:

- risultati esatti principali;
- percentuale;
- variazione rispetto allo snapshot precedente;
- quota di concentrazione.

## 4.4 Consensus dominante

Il consenso non è una previsione ufficiale.

È la scelta più frequente della community.

---

# 5. LONG TREND

## 5.1 Definizione

Evoluzione delle distribuzioni dalla apertura dei pronostici fino al lock.

## 5.2 Finestra

```text
opens_at → lock_at
```

## 5.3 Granularità

La granularità dipende dal volume e dalle prestazioni.

Esempi:

```text
snapshot orario
snapshot a variazione significativa
snapshot giornaliero nelle fasi iniziali
```

## 5.4 Indicatori

```text
direction
change_percent
velocity
stability
late_shift
```

## 5.5 Late Shift

Misura lo spostamento della community nelle ore finali prima del lock.

Non implica maggiore accuratezza.

---

# 6. MOMENTUM

## 6.1 Definizione

Velocità recente con cui una scelta sta guadagnando o perdendo consenso.

## 6.2 Differenza dal Long Trend

```text
Long Trend = evoluzione completa
Momentum = movimento recente
```

## 6.3 Output

```text
rising
stable
falling
```

con intensità normalizzata.

## 6.4 Confine

Il Momentum descrive il comportamento della community.

Non certifica qualità predittiva.

---

# 7. CONFIDENCE E CHAOS

## 7.1 Community Confidence

Misura la concentrazione del consenso.

Alta concentrazione:

```text
confidence alta
```

Distribuzione frammentata:

```text
confidence bassa
```

## 7.2 Chaos

Misura l'incertezza collettiva.

Può considerare:

- dispersione dei segni;
- dispersione degli Exact;
- differenza tra mercati;
- variazioni tardive;
- instabilità del trend.

## 7.3 Uso

Confidence e Chaos aiutano a distinguere:

- partite percepite come leggibili;
- partite percepite come incerte.

Non devono essere presentati come probabilità reali.

---

# 8. SURPRISE TREND

## 8.1 Definizione

Misura quanto gli esiti eleggibili per Bonus Sorpresa vengono selezionati dalla community.

## 8.2 Output

```text
surprise_outcome
surprise_pick_percent
trend
momentum
rank
```

## 8.3 Sorpresa più giocata

La Control Room può evidenziare la sorpresa più selezionata della giornata.

## 8.4 Confine

L'indicatore non afferma che la sorpresa si verificherà.

Mostra soltanto la preferenza collettiva.

---

# 9. ATTACK INTELLIGENCE

## 9.1 Definizione

Aggregazione anonima dell'uso delle partite nel reparto Attacco.

## 9.2 Output

```text
match_id
attack_usage_percent
attack_rank
attack_trend
consensus_context
confidence_context
```

## 9.3 Valore decisionale

Una partita con consenso forte può essere considerata dalla community una candidata naturale per l'Attacco.

La piattaforma non deve suggerirla direttamente.

## 9.4 Visualizzazione

Mostrare:

- quota di utilizzo;
- posizione relativa;
- evoluzione;
- confronto con Difesa.

---

# 10. DEFENSE INTELLIGENCE

## 10.1 Definizione

Aggregazione anonima dell'uso delle partite nel reparto Difesa.

## 10.2 Output

```text
match_id
defense_usage_percent
defense_rank
defense_trend
consensus_context
chaos_context
```

## 10.3 Valore decisionale

Permette di osservare quali eventi vengono trattati dalla community come più adatti alla protezione.

---

# 11. ONE TO ONE INTELLIGENCE

## 11.1 Definizione

Analisi aggregata degli accoppiamenti scelti nelle matrici One To One.

## 11.2 Oggetti

```text
own_match_slot
opponent_match_slot
pairing_count
pairing_percent
pairing_rank
trend
```

## 11.3 Accoppiamenti più scelti

Mostrare:

- coppie più frequenti;
- direzione dell'accoppiamento;
- concentrazione;
- variazione nel tempo.

## 11.4 Privacy

Nessun accoppiamento deve essere ricondotto a:

- utente;
- lega;
- avversario;
- matrice specifica.

---

# 12. PRE-LIVE CONTROL ROOM

## 12.1 Missione

Supportare la costruzione delle decisioni.

## 12.2 Contenuti prioritari

- Exact più giocati;
- distribuzione 1X2;
- distribuzione Over/Under;
- distribuzione Goal/No Goal;
- Consensus;
- Long Trend;
- Momentum;
- Surprise Trend;
- uso Attacco;
- uso Difesa;
- accoppiamenti One To One.

## 12.3 Ordinamento

L'utente deve poter osservare:

- per partita;
- per indicatore;
- per intensità;
- per variazione;
- per livello di consenso.

## 12.4 Nessun suggerimento

Vietati:

- "gioca 1";
- "pronostico consigliato";
- "scelta migliore";
- auto-compilazione;
- ranking di risultati presentati come corretti.

---

# 13. LIVE CONTROL ROOM

## 13.1 Missione

Confrontare la lettura collettiva con lo sviluppo reale.

## 13.2 Contenuti

- consenso pre-lock congelato;
- risultato live;
- percentuale community coerente col risultato corrente;
- andamento delle scelte;
- stato provvisorio.

## 13.3 Bonus e malus

Gol Show, Cantonata e altri esiti maturati non costituiscono il valore principale del live Control Room.

Possono entrare in analisi post-live o storiche.

## 13.4 Immutabilità del consenso pre-lock

Dopo il lock, il dato pre-live resta congelato.

---

# 14. POST-LIVE E VALUTAZIONE

## 14.1 Missione

Misurare conferma o smentita del consenso.

## 14.2 Indicatori

```text
community_sign_accuracy
community_over_under_accuracy
community_goal_no_goal_accuracy
top_exact_hit
surprise_hit
consensus_failure
```

## 14.3 Valore

La fase post-live costruisce lo storico della capacità predittiva della community.

## 14.4 Nessuna riscrittura

Gli snapshot pre-live non vengono modificati dopo il risultato.

---

# 15. HISTORICAL PREDICTABILITY

## 15.1 Definizione

Misura nel tempo quanto la community ha interpretato correttamente:

- squadre;
- competizioni;
- giornate;
- mercati;
- fasce di consenso.

## 15.2 Scope

```text
competition
edition
round
team
match
market
time_window
```

## 15.3 Esempi

- squadre più leggibili;
- squadre che hanno generato più errori collettivi;
- percentuale di successo del consenso forte;
- accuratezza delle sorprese più giocate;
- differenza tra early trend e late trend.

## 15.4 Confine

Le statistiche storiche globali restano anonime.

---

# 16. PRIVACY E SOGLIE

## 16.1 Aggregazione

Ogni output deve essere aggregato.

## 16.2 Soglia minima

Il sistema deve supportare una soglia minima di contributi prima di pubblicare un indicatore.

La soglia è una policy tecnica di protezione e qualità, non un concetto mostrato come dimensione della lega.

## 16.3 Nessuna segmentazione identificativa

Evitare combinazioni di filtri che rendano riconoscibili singoli utenti o gruppi troppo piccoli.

## 16.4 Separazione delle identità

Gli snapshot analytics non devono contenere identificativi utente o lega nei payload pubblicabili.

---

# 17. QUALITÀ DEL DATO

## 17.1 Stati

```text
insufficient
emerging
stable
high_confidence
```

## 17.2 Fattori

- numero contributi;
- copertura della giornata;
- completezza pronostici;
- completezza strategie;
- età dello snapshot;
- stabilità del trend.

## 17.3 Trasparenza

Gli indicatori devono distinguere chiaramente dato stabile e dato emergente.

---

# 18. SNAPSHOT E VERSIONAMENTO

## 18.1 Versione

Ogni snapshot ha versione monotona per round e fase.

## 18.2 Hash

Input e output devono essere hashati in forma canonica.

## 18.3 Fasi congelate

```text
lock snapshot
post_live snapshot
historical snapshot
```

sono immutabili.

## 18.4 Long Trend

È ricostruito dalla sequenza ordinata degli snapshot pre-live.

---

# 19. CONTROL ROOM ACCESS

## 19.1 Natura premium

La Control Room è una sezione a pagamento o accesso controllato.

## 19.2 Accesso

Può essere sbloccata tramite:

- Pass;
- rewarded video;
- premio;
- promozione.

## 19.3 Separazione

Il motore analytics non gestisce:

- saldo Pass;
- pagamenti;
- pubblicità;
- sessioni economiche.

Consuma soltanto una decisione di accesso autorizzata.

## 19.4 Nessun pay-to-win diretto

L'accesso fornisce informazioni aggregate.

Non modifica punteggi, regole o classifiche.

---

# 20. READ MODELS

Read model iniziali:

```text
control_room_round_overview
control_room_match_consensus
control_room_long_trend
control_room_surprise_trend
control_room_attack_usage
control_room_defense_usage
control_room_one_to_one_pairings
control_room_historical_predictability
```

I read model devono essere ottimizzati per consultazione e cache.

---

# 21. PRESTAZIONI

## 21.1 Separazione dal database operativo

Le query analytics non devono rallentare:

- submit pronostici;
- autosave;
- lock;
- scoring;
- live;
- certificazione.

## 21.2 Snapshot

Preferire snapshot preaggregati rispetto a scansioni globali ripetute.

## 21.3 Refresh

Frequenza adattiva:

```text
lontano dal lock → bassa
vicino al lock → maggiore
post lock → congelata
live → confronto, non ricostruzione del consenso
```

---

# 22. SICUREZZA

- Nessun accesso diretto alle prediction individuali.
- Nessun payload pubblico con user_id.
- Nessuna query client sulle tabelle operative.
- Read model controllati.
- Accesso premium verificato prima della lettura.
- Audit degli accessi e delle generazioni snapshot.

---

# 23. OSSERVABILITÀ

Metriche minime:

```text
community_snapshot_build_total
community_snapshot_build_duration
community_snapshot_failed
prediction_contribution_count
strategy_contribution_count
control_room_query_latency
control_room_access_denied
snapshot_staleness
```

Log minimi:

```text
round_id
snapshot_id
phase
version
prediction_count
strategy_count
status
correlation_id
```

---

# 24. EVOLUZIONE PREVISTA

## 24.1 Versione 1.x

- Consensus;
- Exact più giocati;
- Long Trend;
- Momentum;
- Surprise Trend;
- Attack/Defense Intelligence;
- One To One Pairings;
- valutazione post-live;
- storico base.

## 24.2 Futuro

- indici proprietari;
- confronto community vs mercato;
- modelli di prevedibilità;
- AI Coach descrittivo;
- segmentazioni non identificative;
- analisi multi-competizione.

Ogni evoluzione deve mantenere il carattere descrittivo e non prescrittivo.

---

# 25. DECISIONI CONGELATE

- La Control Room usa dati globali.
- Gli output pubblici sono anonimi e aggregati.
- Le statistiche della lega restano separate e nominative.
- Il valore principale della Control Room è pre-live.
- Il Long Trend parte dall'apertura dei pronostici e termina al lock.
- Il consenso pre-lock non viene riscritto dopo i risultati.
- Live e post-live misurano conferma o smentita.
- La Control Room aiuta a decidere ma non decide.
- Attack, Defense e One To One producono analytics dedicati.
- La Control Room non modifica mai Core, Ledger o classifiche.
- L'accesso premium non produce vantaggi artificiali sul punteggio.
- Le query analytics non devono gravare sul database operativo.

---

# DIRETTIVA FINALE

Il Community Intelligence Engine deve trasformare la partecipazione collettiva in conoscenza utile senza trasformarla in prescrizione.

La Control Room deve rendere visibile come la community interpreta una giornata, come tale interpretazione cambia e quanto risulta affidabile nel tempo.

La decisione finale deve restare sempre del giocatore.
