# FANTAGOL LIVE STATE ENGINE MASTER v1

**Stato:** documento fondativo operativo  
**Ambito:** governo degli stati temporali e visivi della giornata FantaGol  
**Obiettivo:** coordinare la transizione pre-live, live, post-live e certified, sincronizzando dati, punteggi provvisori e rappresentazione grafica senza sostituire i motori di calcolo.

---

# 0. PRINCIPI FONDATIVI

## 0.1 Il Live State Engine coordina

Il Live State Engine non calcola il punteggio.

Coordina:

- stato temporale del round;
- stato delle partite;
- stato dei punteggi;
- transizioni;
- aggiornamento del Digital Twin;
- pubblicazione verso i client;
- segnali grafici live.

## 0.2 Il live è una fase provvisoria

Durante il live:

- risultati e punteggi possono cambiare;
- le icone possono accendersi e spegnersi;
- le classifiche sono preview;
- nessun risultato è definitivo prima della certificazione.

## 0.3 Il tempo è parte del dominio

Le partite di una giornata sono distribuite su più giorni e orari.

Il sistema deve rappresentare contemporaneamente:

- eventi futuri;
- eventi in corso;
- eventi conclusi;
- eventi rinviati;
- giornata non ancora certificata.

## 0.4 La grafica comunica senza spiegazioni

Le differenze tra pre-live, live, post-live e certified devono essere percepibili tramite:

- pulsazione;
- contrasto;
- luminosità;
- stabilità;
- transizioni;
- stato delle icone;
- stato del punteggio.

## 0.5 La fine del live non coincide con la certificazione

Una partita può essere conclusa ma non ancora certificata.

Una giornata può avere tutte le partite concluse ma attendere:

- validazione;
- calculation run finale;
- commit;
- ledger;
- aggiornamento classifiche.

---

# 1. ENGINE CONTRACT

## 1.1 Nome

```text
LiveStateEngine
```

## 1.2 Artefatto principale

```text
LiveStateSnapshot
```

## 1.3 Input

```text
ProviderMatchUpdates
NormalizedMatchState
LatestRoundSimulation
LeagueRoundStatus
CalculationRunStatus
CertificationStatus
```

## 1.4 Output

```text
LiveStateSnapshot
MatchLiveState
RoundLiveState
ScoreLiveState
VisualState
RealtimePublication
```

## 1.5 Comandi

```text
ApplyMatchUpdate
OpenRoundLiveState
RefreshRoundLiveState
CloseMatchLiveState
MarkRoundAwaitingFinalCalculation
PublishCertifiedLiveState
InvalidateLiveState
```

## 1.6 Eventi

```text
MatchEnteredLive
MatchScoreChanged
MatchLeftLive
MatchPostLiveAcquired
RoundEnteredLive
RoundLiveProgressChanged
RoundAwaitingFinalCalculation
RoundCertified
LiveStatePublished
```

## 1.7 Query

```text
GetCurrentLiveState
GetMatchLiveState
GetRoundLiveTimeline
GetLatestPublishedLiveSnapshot
```

---

# 2. POSIZIONE NELL'ARCHITETTURA

```text
Provider
   ↓
Provider Adapter
   ↓
Normalized Match Update
   ↓
Resolution Engine
   ↓
Round Simulation Engine
   ↓
LIVE STATE ENGINE
   ↓
Realtime Publication
   ↓
Web / Android / Control Room
```

Il Live State Engine orchestra la sequenza.

Non sostituisce Resolution e Simulation.

---

# 3. LE QUATTRO FASI

## 3.1 Pre-live

La partita non è iniziata.

Caratteristiche:

- risultato assente;
- punteggio non attivo;
- icone spente;
- card statica;
- Bonus Sorpresa eventualmente `candidate`;
- nessuna pulsazione.

## 3.2 Live

La partita è in corso.

Caratteristiche:

- risultato provvisorio;
- punteggio provvisorio;
- icone dinamiche;
- card con lieve pulsazione;
- punteggio con lieve pulsazione;
- aggiornamenti a ogni variazione significativa.

## 3.3 Post-live

La partita è conclusa e il risultato è acquisito.

Caratteristiche:

- card statica distinta dal pre-live;
- icone accese solo se effettivamente ottenute;
- punteggio non più dipendente dal risultato della singola partita;
- giornata ancora potenzialmente provvisoria;
- nessuna pulsazione della card partita.

## 3.4 Certified

La giornata è stata committata e le classifiche aggiornate.

Caratteristiche:

- punteggi bloccati;
- icone bloccate;
- Digital Twin collegato alla certificazione;
- stato grafico stabile;
- nessuna pulsazione;
- classifica ufficiale disponibile.

---

# 4. MATCH LIVE STATE

## 4.1 Stati

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

## 4.2 Transizioni principali

```text
scheduled → imminent
imminent → live
live → halftime
halftime → live
live → post_live
post_live → certified
scheduled → postponed
live → postponed
scheduled → cancelled
```

## 4.3 Imminent

Stato opzionale per eventi prossimi all'inizio.

Non implica pulsazione live.

Può aumentare leggermente la rilevanza visiva senza simulare un evento già iniziato.

## 4.4 Postponed

Un evento rinviato deve apparire:

- separato dai futuri ordinari;
- non live;
- non concluso;
- senza punti definitivi;
- collegato alla policy di recupero.

---

# 5. ROUND LIVE STATE

## 5.1 Stati

```text
pre_live
partially_live
live
partially_post_live
awaiting_final_calculation
awaiting_certification
certified
waiting_postponed
```

## 5.2 Regole

### pre_live

Nessuna partita è iniziata.

### partially_live

Almeno una partita è live e almeno una è ancora futura.

### live

Esistono partite live.

### partially_post_live

Non esistono partite live, ma la giornata non è completa oppure restano eventi futuri.

### awaiting_final_calculation

Tutte le partite richieste sono concluse e il calcolo finale non è ancora completato.

### awaiting_certification

La preview finale è pronta ma non ancora committata.

### certified

Ledger e classifiche ufficiali sono aggiornati.

### waiting_postponed

La giornata resta aperta per eventi rinviati inclusi.

---

# 6. SCORE LIVE STATE

## 6.1 Stati

```text
waiting
provisional
stable_pending_round
final_pending_commit
locked
void
```

## 6.2 waiting

Nessun evento rilevante è iniziato.

## 6.3 provisional

Il punteggio può ancora cambiare a causa di partite live.

## 6.4 stable_pending_round

La singola partita è conclusa, ma il totale di giornata può cambiare.

## 6.5 final_pending_commit

Tutte le partite richieste sono concluse, ma manca la certificazione.

## 6.6 locked

Il punteggio è certificato.

## 6.7 Pulsazione del punteggio

Il punteggio pulsa lievemente quando è provvisorio.

La pulsazione termina soltanto quando:

- non esistono eventi live;
- il calcolo finale è completato;
- la commit finale è avvenuta;
- le classifiche ufficiali sono aggiornate.

Questa scelta crea un segnale intuitivo di ufficialità.

---

# 7. ICON STATE MODEL

## 7.1 Stati comuni

```text
off
candidate
live_active
live_inactive
on
locked_on
locked_off
```

## 7.2 Pre-live

Tutte le icone sono `off`.

Eccezione:

```text
Bonus Sorpresa = candidate
```

quando il pronostico seleziona un esito eleggibile.

## 7.3 Candidate Sorpresa

Aspetto:

- cerchio esterno acceso;
- nucleo centrale spento;
- nessuna pulsazione;
- nessuna indicazione di assegnazione.

## 7.4 Live

Le icone seguono il risultato corrente.

Possono:

- accendersi;
- spegnersi;
- cambiare stato;
- pulsare lievemente.

## 7.5 Post-live

Restano accese soltanto le icone effettivamente conseguite.

Non pulsano.

## 7.6 Certified

Le icone assumono stato bloccato.

```text
locked_on
locked_off
```

---

# 8. VISUAL STATE MODEL

## 8.1 Obiettivo

Trasmettere la fase senza introdurre etichette ridondanti.

## 8.2 Pre-live

- card neutra;
- contrasto normale;
- nessuna pulsazione;
- risultato non valorizzato;
- icone spente.

## 8.3 Live

- lieve pulsazione della card;
- risultato evidenziato;
- punteggio provvisorio pulsante;
- icone dinamiche;
- aggiornamenti fluidi.

## 8.4 Post-live

- card statica;
- aspetto visivamente acquisito;
- contrasto distinto dagli eventi futuri;
- punteggio stabile della partita;
- icone definitive della partita.

## 8.5 Certified

- aspetto consolidato;
- punteggio bloccato;
- nessuna animazione;
- collegamento implicito alla classifica aggiornata.

## 8.6 Intensità

Le animazioni devono essere lievi.

Il live deve risultare vivo, non rumoroso.

---

# 9. TIMELINE

## 9.1 Scopo

La Timeline descrive l'evoluzione della giornata.

## 9.2 Eventi minimi

```text
predictions_locked
match_started
score_changed
halftime
match_finished
round_all_matches_finished
final_calculation_started
final_calculation_completed
certification_committed
standings_updated
```

## 9.3 Ordinamento

Gli eventi sono ordinati per timestamp e mantengono:

```text
occurred_at
received_at
processed_at
source
correlation_id
```

## 9.4 Replay

La conservazione della Timeline deve permettere in futuro il replay della giornata.

---

# 10. PROVIDER UPDATE POLICY

## 10.1 I client non interrogano i provider

Tutti gli aggiornamenti passano attraverso il backend FantaGol.

## 10.2 Aggiornamenti significativi

Persistire e propagare soltanto:

- cambio stato;
- cambio risultato;
- inizio;
- intervallo;
- ripresa;
- fine;
- rinvio;
- annullamento;
- assegnazione a tavolino.

## 10.3 Polling adattivo

```text
nessuna partita vicina → frequenza bassa
partita imminente → frequenza media
partita live → frequenza alta
nessuna partita live → riduzione
round certificato → stop
```

## 10.4 Idempotenza

Lo stesso aggiornamento provider non deve generare più eventi equivalenti.

---

# 11. REFRESH PIPELINE

```text
Provider Update
      ↓
Normalize
      ↓
Persist Match State
      ↓
Resolution Rebuild
      ↓
Round Simulation Rebuild
      ↓
Live State Rebuild
      ↓
Realtime Publish
```

Ogni passaggio deve essere tracciabile.

---

# 12. REALTIME PUBLICATION

## 12.1 Oggetto pubblicato

Il client riceve un riferimento o payload coerente con:

```text
live_snapshot_id
round_simulation_id
version
published_at
```

## 12.2 Coerenza atomica

Non pubblicare un punteggio nuovo insieme a uno stato icone appartenente alla versione precedente.

## 12.3 Client recovery

In caso di perdita di eventi realtime, il client deve poter richiedere l'ultimo snapshot completo.

## 12.4 Ordine

Il client ignora aggiornamenti con versione inferiore a quella già applicata.

---

# 13. RAPPORTO CON LA CERTIFICAZIONE

## 13.1 Fine dell'ultima partita

La fine dell'ultima partita non aggiorna automaticamente le classifiche ufficiali.

Genera:

```text
RoundAwaitingFinalCalculation
```

## 13.2 Calcolo finale

Quando il calcolo finale è pronto:

```text
RoundAwaitingCertification
```

## 13.3 Commit

La commit finale produce:

- ledger;
- classifiche ufficiali;
- certificazione;
- stato `certified`;
- termine delle pulsazioni.

## 13.4 Esperienza utente

La cessazione delle pulsazioni comunica intuitivamente che la giornata è ufficiale.

Non è previsto alcun reindirizzamento automatico alla pagina classifiche.

---

# 14. RINVII

## 14.1 Rinvio prima dell'inizio

La partita passa a `postponed`.

## 14.2 Rinvio durante il live

Il risultato corrente resta storico ma non viene trattato come finale salvo policy esplicita.

## 14.3 Round waiting_postponed

La giornata può restare aperta.

Il Digital Twin deve distinguere:

- punteggi acquisiti;
- punteggi sospesi;
- eventi ancora pendenti.

## 14.4 Riapertura

Una riapertura per recupero deve generare nuova Timeline e nuove simulazioni.

---

# 15. ERRORI E DEGRADAZIONE

## 15.1 Stati

```text
healthy
degraded
stale
unavailable
```

## 15.2 Stale

Se il provider non aggiorna entro la soglia prevista:

- mantenere l'ultimo snapshot;
- non inventare cambiamenti;
- indicare internamente lo stato stale;
- evitare false transizioni.

## 15.3 Recupero

Alla ripresa del provider, il sistema confronta lo stato corrente e applica soltanto le differenze significative.

---

# 16. SICUREZZA

- Nessuna scrittura live dal client.
- Nessun accesso diretto ai provider dal client.
- Pronostici e strategie rispettano le regole di visibilità.
- Gli aggiornamenti realtime non devono esporre payload privati.
- Service role e worker operano tramite funzioni controllate.

---

# 17. OSSERVABILITÀ

Metriche minime:

```text
live_updates_received
live_updates_applied
live_updates_ignored_duplicate
live_state_publish_latency
simulation_rebuild_latency
stale_provider_duration
realtime_publish_failed
```

Log minimi:

```text
match_id
league_round_id
provider_update_id
live_snapshot_id
simulation_id
state_before
state_after
correlation_id
```

---

# 18. EVOLUZIONE PREVISTA

## 18.1 Versione 1.x

- live risultati;
- live punteggi;
- pulsazioni;
- transizioni pre/live/post/certified;
- realtime Web e Android;
- gestione rinvii.

## 18.2 Futuro

- replay giornata;
- notifiche intelligenti;
- highlight automatici;
- timeline pubblica;
- widget;
- sincronizzazione multi-competizione.

---

# 19. DECISIONI CONGELATE

- Il Live State Engine non calcola punti.
- Le card partita pulsano lievemente solo durante il live.
- I punteggi provvisori pulsano fino alla commit finale della giornata.
- Le classifiche ufficiali si aggiornano con commit unico.
- Nessun reindirizzamento automatico alle classifiche.
- Pre-live, live, post-live e certified sono fasi visivamente distinte.
- Le icone live sono dinamiche.
- Le icone post-live sono statiche e riflettono il risultato acquisito.
- Il Bonus Sorpresa possiede uno stato candidate pre-live.
- Il client consuma snapshot coerenti e versionati.
- La fine dell'ultima partita non equivale automaticamente alla certificazione.

---

# DIRETTIVA FINALE

Il Live State Engine deve rendere percepibile il tempo del gioco senza alterare la verità del gioco.

Ogni transizione deve essere coerente, tracciabile e intuitiva.

L'utente deve comprendere se un evento è futuro, vivo, acquisito o ufficiale osservando l'esperienza, senza dover leggere spiegazioni aggiuntive.
