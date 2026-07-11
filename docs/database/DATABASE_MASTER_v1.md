# FANTAGOL DATABASE MASTER v1

**Stato:** baseline progettuale per l'avvio del backend dinamico  
**Data:** 2026-07-11  
**Fonte reale:** audit Supabase `SUPABASE_TECHNICAL_AUDIT_2026-07-11.md`  
**Principio:** estensione non distruttiva dello schema esistente.

## 1. Obiettivi

Il database deve alimentare web e app Android con un solo backend e supportare:

- autenticazione e profilo;
- club personale riutilizzabile in più leghe;
- calendario Serie A, giornate e risultati live;
- un unico set di pronostici per tutte le modalità;
- Punti Puri;
- Fantacalcio con 5 partite in Attacco e 5 in Difesa;
- One To One con due matrici indipendenti da 10 mini-sfide;
- punteggio provvisorio, finale e ricalcolato;
- provider multipli per calendario, live e quote;
- futura Control Room e sistema Pass.

## 2. Regole architetturali

1. `predictions` conserva soltanto il pronostico base.
2. Le scelte strategiche sono salvate in tabelle separate.
3. Il client non scrive direttamente strutture strategiche complete: usa RPC transazionali.
4. Il numero di utenti non deve moltiplicare le chiamate ai provider esterni.
5. Gli aggiornamenti live vengono centralizzati nel database e letti da tutti i client.
6. Ogni calcolo deve poter essere ripetuto in modo deterministico.
7. I dati provvisori devono essere distinguibili da quelli ufficiali.
8. I pronostici altrui non devono essere leggibili prima del lock della giornata.

## 3. Entità esistenti mantenute

### `profiles`
Profilo applicativo collegato 1:1 a `auth.users`.

Campi esistenti principali:
- `id`
- `email`
- `avatar_url`
- `last_active_league_id`
- `created_at`

### `clubs`
Identità sportiva personale dell'utente, condivisa tra le leghe.

Relazione:
- `clubs.owner_id -> auth.users.id`
- un solo club per proprietario.

### `leagues`
Contenitore delle tre modalità di gioco.

Relazioni:
- `owner_id -> auth.users.id`
- `season_id -> seasons.id`

### `league_members`
Appartenenza di un utente a una lega.

Vincolo esistente:
- unique `(league_id, user_id)`.

### `seasons`
Stagione calcistica reale.

### `matchdays`
Giornata reale della stagione. Rimane l'entità canonica; non viene introdotta una tabella duplicata `rounds`.

### `teams`
Squadre reali. Gli stemmi non sono requisito del motore dati.

### `matches`
Partite reali con kickoff, risultato e stato.

### `predictions`
Pronostico base di un utente per una partita in una lega.

Vincolo esistente:
- unique `(league_id, user_id, match_id)`.

## 4. Estensioni alla struttura esistente

### `matchdays`
Nuovi campi:

- `lock_at timestamptz`: istante di blocco globale della giornata;
- `status text`: `scheduled`, `open`, `locked`, `live`, `partial`, `final`, `recalculated`;
- `official_at timestamptz`;
- `updated_at timestamptz`.

### `matches`
Nuovi campi:

- `provider_name text`;
- `provider_match_id text`;
- `minute integer`;
- `live_updated_at timestamptz`;
- `result_version integer`;
- `updated_at timestamptz`.

### `predictions`
Nuovi campi:

- `status text`: `draft`, `submitted`, `locked`, `void`;
- `submitted_at timestamptz`;
- `locked_at timestamptz`;
- `version integer`.

## 5. Modalità abilitate per lega

### `league_modes`

Una riga per ciascuna modalità della lega.

Campi:
- `league_id`
- `mode`: `punti_puri`, `fantacalcio`, `one_to_one`
- `enabled`
- `settings jsonb`
- `created_at`
- `updated_at`

PK:
- `(league_id, mode)`

## 6. Fantacalcio strategico

### `fantacalcio_allocations`

Salva la distribuzione delle 10 partite in due reparti.

Campi:
- `league_id`
- `matchday_id`
- `user_id`
- `match_id`
- `phase`: `attack` o `defense`
- `position`: da 1 a 5 dentro il reparto
- `created_at`
- `updated_at`

Vincoli:
- una sola assegnazione per partita e utente;
- posizione unica in ciascun reparto;
- il salvataggio ufficiale deve contenere esattamente 5 `attack` e 5 `defense`;
- tutte le partite devono appartenere alla giornata indicata;
- l'utente deve essere membro attivo della lega;
- la giornata deve essere ancora aperta.

### Modificatori ufficiali

Attacco:
- Exact ×2;
- Bonus Sorpresa ×2;
- Segno Opposto ×2;
- Cantonata ×2.

Difesa:
- bonus invariati;
- Segno Opposto ×0,5;
- Cantonata ×0,5.

I valori dimezzati possono produrre decimali; i punti strategici devono quindi usare `numeric`, non solo `integer`.

## 7. Calendari delle sfide tra utenti

### `league_fixtures`

Accoppiamento tra due utenti per una modalità e una giornata.

Campi:
- `id`
- `league_id`
- `matchday_id`
- `mode`: `fantacalcio` o `one_to_one`
- `home_user_id`
- `away_user_id`
- `status`
- `created_at`
- `updated_at`

Vincoli:
- utenti diversi;
- una coppia unica per lega, giornata e modalità;
- entrambi membri attivi della lega.

## 8. One To One strategico

### Concetto

Ogni fixture One To One genera due matrici indipendenti:

- matrice costruita dal giocatore A;
- matrice costruita dal giocatore B.

Ogni matrice è una permutazione 1:1 delle dieci partite:

- ciascun pronostico proprio viene usato una sola volta;
- ciascun pronostico avversario viene bersagliato una sola volta;
- le matrici dei due giocatori possono essere completamente diverse.

### `one_to_one_matrix_entries`

Campi:
- `id`
- `fixture_id`
- `strategist_user_id`
- `opponent_user_id`
- `source_match_id`: partita del pronostico proprio;
- `target_match_id`: partita del pronostico avversario;
- `slot_number`: 1..10;
- `created_at`
- `updated_at`

Vincoli:
- unique `(fixture_id, strategist_user_id, source_match_id)`;
- unique `(fixture_id, strategist_user_id, target_match_id)`;
- unique `(fixture_id, strategist_user_id, slot_number)`;
- il `strategist_user_id` deve essere uno dei due utenti della fixture;
- `opponent_user_id` deve essere l'altro utente;
- le partite devono appartenere alla giornata della fixture;
- la matrice ufficiale deve avere esattamente 10 righe.

## 9. Salvataggio transazionale

### `save_fantacalcio_strategy_rpc`
Riceve due array UUID da 5 elementi (`attack_match_ids`, `defense_match_ids`).

La funzione:
1. verifica autenticazione e membership;
2. verifica che gli array contengano 5 elementi ciascuno;
3. verifica 10 partite uniche;
4. verifica appartenenza alla stessa giornata;
5. verifica che la giornata non sia bloccata;
6. sostituisce atomically la strategia precedente.

### `save_one_to_one_matrix_rpc`
Riceve:
- `fixture_id`;
- array `source_match_ids` di 10 elementi;
- array `target_match_ids` di 10 elementi.

La funzione:
1. determina l'avversario;
2. verifica la fixture;
3. verifica due permutazioni complete e senza duplicati;
4. verifica la giornata aperta;
5. sostituisce atomicamente solo la matrice dell'utente chiamante.

## 10. Sicurezza RLS

### Dati pubblici
Lettura pubblica consentita soltanto per:
- stagioni;
- giornate;
- squadre;
- partite e risultati reali.

### Dati privati
- club: solo proprietario;
- profilo: solo proprietario;
- strategia Fantacalcio: proprietario, poi avversario/lega secondo stato giornata;
- matrice One To One: autore prima del lock; partecipanti della fixture dopo il lock;
- pronostici: autore prima del lock; membri della stessa lega dopo il lock.

### Correzione necessaria
La policy attuale `Public read predictions` è incompatibile con il gioco competitivo e deve essere rimossa prima della beta pubblica.

### RPC
Le funzioni applicative devono essere eseguibili da `authenticated`, non genericamente da `PUBLIC`.

## 11. Indici prioritari

Oltre agli indici unici:

- `matches(matchday_id, kickoff)`;
- `matches(provider_name, provider_match_id)`;
- `predictions(league_id, match_id)`;
- `predictions(user_id, match_id)`;
- `fantacalcio_allocations(league_id, matchday_id, user_id)`;
- `league_fixtures(league_id, matchday_id, mode)`;
- `one_to_one_matrix_entries(fixture_id, strategist_user_id)`.

## 12. Tabelle previste nelle fasi successive

Non incluse nella migrazione 001:

- `odds_provider_snapshots`;
- `odds_consensus_snapshots`;
- `prediction_score_components`;
- `round_user_scores`;
- `mode_match_results`;
- `standings_snapshots`;
- `provider_sync_runs`;
- `admin_audit_log`;
- `control_room_pass_ledger`;
- `control_room_access_sessions`.

Queste dipenderanno dal consolidamento di provider e scoring engine.

## 13. Ordine di implementazione

1. Migrazione 001: strategia e hardening minimo.
2. Test su una lega e una giornata fittizia.
3. Collegamento pagina pronostici.
4. Collegamento Fantacalcio Attacco/Difesa.
5. Collegamento One To One matrici.
6. Provider calendario/live.
7. Scoring engine.
8. Classifiche.
9. Control Room.

## 14. Decisioni deliberate

- `matchdays` resta il nome canonico invece di creare `rounds`.
- le strategie non sono colonne di `predictions`;
- le matrici One To One sono memorizzate come righe normalizzate, non JSON;
- i vincoli di completezza 5/5 e 10/10 sono applicati dalle RPC transazionali;
- nessuna dipendenza diretta da un singolo provider esterno.
