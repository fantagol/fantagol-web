# FANTAGOL — WORKFLOW ENGINE FINAL AUDIT

## Milestone 7.2.5 — Architectural Certification

**Data:** 19 luglio 2026  
**Commit di riferimento:** `568e221`  
**Repository:** `fantagol/fantagol-web`

---

# 1. Obiettivo

La Milestone 7.2.5 certifica lo stato finale dell’architettura di orchestrazione del Live Runtime di FantaGol.

L’obiettivo dell’audit era verificare che tutte le transizioni di dominio fossero instradate attraverso il Workflow Engine e che gli enqueue diretti residui appartenessero esclusivamente a una delle seguenti categorie:

- primitive infrastrutturali;
- scheduler e timer;
- bootstrap o ingestion;
- meccanismi tecnici del Job Engine.

---

# 2. Risultato sintetico

L’audit ha confermato che nel Live Runtime non sono più presenti enqueue diretti utilizzati per collegare due fasi business.

Il principio architetturale seguente risulta quindi rispettato:

```text
Business transition
        │
        ▼
Workflow
        │
        ▼
Workflow step
        │
        ▼
Job Engine
        │
        ▼
Worker
```

Gli enqueue diretti residui sono coerenti con il livello infrastrutturale del sistema.

---

# 3. Workflow di dominio certificati

Il runtime include i seguenti workflow applicativi:

| Workflow | Sorgente | Job eseguito |
|---|---|---|
| Certification Readiness Workflow | `refresh_round` | `evaluate_certification_readiness` |
| Match Result Certification Workflow | `evaluate_certification_readiness` | `certify_match_result` |
| Round Certification Readiness Workflow | `rebuild_league_round` | `evaluate_round_certification_readiness` |
| Round Certification Workflow | `evaluate_round_certification_readiness` | `certify_round` |
| Certified Snapshot Publication Workflow | `certify_round` | `publish_snapshot` |

Tutti i workflow sono costruiti tramite la Workflow Factory, creati in modo idempotente e lanciati tramite il Workflow Launcher.

---

# 4. Classificazione degli enqueue diretti residui

## 4.1 `job-service.ts`

**Categoria:** Runtime primitive  
**Valutazione:** conforme

Espone `enqueueLiveRuntimeJob()` come primitiva di basso livello del Job Engine.

Non rappresenta una transizione di dominio e deve rimanere disponibile al runtime, agli scheduler e al Workflow Engine.

---

## 4.2 `scheduler.ts`

**Categoria:** Scheduler  
**Valutazione:** conforme

Pianifica il job `poll_match` in base alla polling policy e al prossimo intervallo calcolato.

La responsabilità è temporale e infrastrutturale:

```text
Polling policy
      │
      ▼
scheduledAt
      │
      ▼
poll_match
```

Non è richiesta la creazione di un workflow.

---

## 4.3 `certification-readiness-handler.ts`

**Categoria:** Timer / scheduled retry  
**Valutazione:** conforme

Quando la partita è ancora nello stato `stabilizing`, il sistema ripianifica:

```text
evaluate_certification_readiness
```

all’istante determinato da `ready_at`.

Quando invece la certificazione è pronta, la transizione business utilizza correttamente il Match Result Certification Workflow.

La distinzione è quindi corretta:

```text
Non pronta → timer tecnico
Pronta     → workflow di dominio
```

---

## 4.4 `orchestrator.ts`

**Categoria:** Ingestion infrastructure  
**Valutazione:** conforme

L’orchestrator riceve un aggiornamento normalizzato proveniente dal provider e avvia `refresh_round`.

Questo punto rappresenta l’ingresso del dato esterno nel Live Runtime, non il passaggio tra due stati business già governati dal dominio.

La funzione resta una frontiera infrastrutturale:

```text
Provider update
      │
      ▼
Receipt / ingestion
      │
      ▼
refresh_round
```

---

## 4.5 `rebuild-enqueue.ts`

**Categoria:** Infrastructure fan-out  
**Valutazione:** conforme

Genera i job `rebuild_league_round` per le leghe interessate da un aggiornamento di partita.

Il fan-out dipende dal numero dinamico di league round coinvolti ed è una responsabilità infrastrutturale di distribuzione del lavoro.

La successiva transizione verso la certificazione di giornata è già governata dal Round Certification Readiness Workflow.

---

# 5. Enqueue business residui

**Nessuno.**

Non risultano handler che eseguano direttamente un enqueue per avviare una fase successiva di certificazione, pubblicazione o avanzamento del dominio.

---

# 6. Pipeline certificata

## 6.1 Pipeline partita

```text
Provider polling
      │
      ▼
poll_match
      │
      ▼
Provider ingestion
      │
      ▼
refresh_round
      │
      ▼
Certification Readiness Workflow
      │
      ▼
evaluate_certification_readiness
      │
      ├── stabilizing → scheduled retry
      │
      └── ready
             │
             ▼
Match Result Certification Workflow
             │
             ▼
certify_match_result
```

## 6.2 Pipeline giornata e pubblicazione

```text
refresh_round
      │
      ▼
rebuild_league_round
      │
      ▼
Round Certification Readiness Workflow
      │
      ▼
evaluate_round_certification_readiness
      │
      ▼
Round Certification Workflow
      │
      ▼
certify_round
      │
      ▼
Certified Snapshot Publication Workflow
      │
      ▼
publish_snapshot
```

---

# 7. Proprietà architetturali raggiunte

Il Workflow Engine garantisce ora:

- idempotenza dei lanci;
- identificazione persistente del workflow;
- step tracciabili;
- correlazione e causazione;
- riconciliazione tra workflow e job;
- separazione tra orchestrazione business e Job Engine;
- retry tecnici distinti dalle transizioni di dominio;
- auditabilità della pipeline;
- foundation per recovery e osservabilità operativa.

---

# 8. Decisione architetturale

La migrazione delle transizioni business al Workflow Engine è dichiarata completa.

Da questa milestone in avanti:

1. nuove transizioni di dominio devono essere introdotte tramite workflow;
2. `enqueueLiveRuntimeJob()` può essere usato direttamente solo per primitive infrastrutturali, scheduler, timer, ingestion o bootstrap;
3. ogni eccezione deve essere documentata e sottoposta ad audit architetturale;
4. il Workflow Engine costituisce il layer ufficiale di orchestrazione del Live Runtime.

---

# 9. Stato della milestone

```text
Milestone: 7.2.5
Nome: Workflow Engine Final Audit
Stato: COMPLETATA
Esito: ARCHITECTURALLY CERTIFIED
```

Il Workflow Engine di FantaGol può essere considerato architetturalmente completo per l’attuale perimetro del Live Runtime.

---

# 10. Fase successiva raccomandata

La fase successiva non deve introdurre ulteriori conversioni meccaniche di enqueue.

Il lavoro dovrebbe concentrarsi su:

- Workflow Observability;
- diagnostica degli step;
- recovery controllato;
- strumenti Control Room;
- visualizzazione di workflow bloccati, falliti o in retry;
- procedure operative per replay e riconciliazione.

Questa evoluzione consoliderà il Workflow Engine come sistema operativo osservabile e amministrabile, oltre che come fondazione architetturale.
