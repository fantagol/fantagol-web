# FANTAGOL — COMMERCIAL SECRET RESOLUTION FINAL AUDIT

## Certificazione architetturale delle Migration 127–140

**Versione:** 1.0
**Data:** 22 luglio 2026
**Stato:** FINAL AUDIT — CERTIFIED
**Dominio:** Commercial Platform / Secret Resolution Governance
**Repository:** `fantagol/fantagol-web`
**Perimetro:** Migration `127`–`140`

---

# 1. Executive Summary

Il presente audit certifica la chiusura architetturale della **Commercial Secret Resolution Passive Foundation** di FantaGol.

Il perimetro verificato comprende quattordici migration organizzate in sette coppie consecutive:

```text
Foundation
    ↓
Lifecycle Certification
```

La catena risultante è:

```text
Secret Backend Registry
        ↓
Reference Resolution Gateway
        ↓
Policy Scope Enforcement
        ↓
Authorization Handoff
        ↓
Execution Permit
        ↓
Dispatch Envelope
        ↓
Dispatch Admission Ticket
```

L’audit conferma che la catena:

- è completa nel perimetro passivo previsto;
- conserva lineage e dipendenze fra tutti i livelli;
- applica idempotenza e protezione dai replay conflittuali;
- utilizza oggetti immutabili o append-only;
- espone read model dedicati;
- abilita Row Level Security sulle tabelle di foundation;
- limita l’accesso mediante `REVOKE` e `GRANT` espliciti;
- vieta la persistenza di secret in chiaro e di endpoint operativi;
- non autorizza dispatch, esecuzione, contatto backend o accesso di rete;
- non produce mutazioni economiche o runtime;
- certifica i lifecycle mediante transazioni concluse con `ROLLBACK`.

Non è emersa alcuna lacuna che richieda una Migration 141 correttiva.

---

# 2. Obiettivo della fase

L’obiettivo non era integrare un secret manager reale né recuperare credenziali.

La fase doveva costruire il layer di governance che precede un’eventuale esecuzione futura, assicurando che ogni passaggio fosse:

```text
policy-driven
metadata-only
provider-independent
lineage-preserving
replay-safe
non-executable
auditable
```

La foundation doveva inoltre restare neutrale rispetto a:

- provider di pagamento;
- provider pubblicitari;
- secret manager;
- infrastrutture cloud;
- rete;
- Wallet;
- Ledger;
- acquisti;
- checkout;
- callback;
- reconciliation;
- outbox commerciale.

L’obiettivo è stato raggiunto.

---

# 3. Perimetro delle migration

| Migration | Componente | Tipo |
|---|---|---|
| 127 | Commercial Provider Secret Backend Registry | Foundation |
| 128 | Secret Backend Registry Lifecycle | Certification |
| 129 | Backend Reference Resolution Gateway | Foundation |
| 130 | Reference Resolution Gateway Lifecycle | Certification |
| 131 | Secret Reference Policy Scope Enforcement | Foundation |
| 132 | Policy Scope Enforcement Lifecycle | Certification |
| 133 | Resolution Authorization Handoff | Foundation |
| 134 | Authorization Handoff Lifecycle | Certification |
| 135 | Secret Resolution Execution Permit | Foundation |
| 136 | Execution Permit Lifecycle | Certification |
| 137 | Secret Resolution Dispatch Envelope | Foundation |
| 138 | Dispatch Envelope Lifecycle | Certification |
| 139 | Secret Resolution Dispatch Admission | Foundation |
| 140 | Dispatch Admission Lifecycle | Certification |

Le migration dispari introducono strutture persistenti e contratti di dominio.

Le migration pari certificano i lifecycle mediante dati temporanei, guard, conteggi, neutralità e rollback.

---

# 4. Risultato dell’analisi statica

L’analisi dei file SQL 127–140 ha rilevato:

| Elemento | Totale |
|---|---:|
| File SQL verificati | 14 |
| Righe complessive | 23.856 |
| Dimensione complessiva | 944.470 byte |
| Tabelle introdotte | 63 |
| Tabelle con RLS abilitata | 63 |
| Read model | 7 |
| Trigger | 56 |
| Funzioni SQL/PLpgSQL uniche nelle foundation | 74 |
| Istruzioni `REVOKE` | 121 |
| Istruzioni `GRANT` | 114 |
| Lifecycle con rollback esplicito | 7 |

## 4.1 Distribuzione per foundation

| Migration | Tabelle | Read model | Trigger | RLS |
|---|---:|---:|---:|---:|
| 127 | 8 | 1 | 7 | 8 |
| 129 | 9 | 1 | 7 | 9 |
| 131 | 7 | 1 | 7 | 7 |
| 133 | 9 | 1 | 8 | 9 |
| 135 | 10 | 1 | 9 | 10 |
| 137 | 10 | 1 | 9 | 10 |
| 139 | 10 | 1 | 9 | 10 |
| **Totale** | **63** | **7** | **56** | **63** |

Tutte le tabelle introdotte dalle foundation risultano sottoposte a Row Level Security.

---

# 5. Architettura certificata

## 5.1 Secret Backend Registry

La Migration 127 introduce il registro canonico dei backend di secret.

Responsabilità:

- registrazione del backend;
- versionamento;
- capability dichiarate;
- binding passivi;
- validazione;
- receipt;
- eventi;
- registrazione dei tentativi di probe bloccati.

Oggetti principali:

```text
commercial_secret_backends
commercial_secret_backend_versions
commercial_secret_backend_capabilities
commercial_secret_backend_bindings
commercial_secret_backend_validation_receipts
commercial_secret_backend_probe_attempts
commercial_secret_backend_events
```

Il registry memorizza esclusivamente riferimenti opachi e metadati.

Non memorizza:

```text
secret
password
token
private key
connection string
operational endpoint
credential material
```

La Migration 128 certifica:

- creazione della catena temporanea backend/version/capability/binding;
- validazione;
- protezioni di immutabilità;
- blocco di configurazioni non sicure;
- neutralità commerciale;
- rollback completo.

---

## 5.2 Reference Resolution Gateway

La Migration 129 introduce il gateway di risoluzione dei riferimenti.

Responsabilità:

- intake delle richieste;
- idempotenza;
- selezione del binding;
- verifica namespace;
- verifica capability;
- decisione;
- costruzione di un route manifest passivo;
- registrazione di tentativi bloccati.

Il route manifest non è una rotta di rete e non contiene endpoint operativi.

È un oggetto metadata-only che descrive il percorso logico autorizzato.

La Migration 130 certifica:

- richiesta;
- replay idempotente;
- rilevamento del conflitto;
- candidate selection;
- decisione;
- manifest;
- tentativo operativo bloccato;
- guard;
- neutralità;
- rollback.

---

## 5.3 Policy Scope Enforcement

La Migration 131 introduce il controllo di autorizzazione sui riferimenti.

Il livello verifica:

- ownership del namespace;
- scope richiesto;
- capability;
- trust tier;
- binding validato;
- contratto;
- policy applicabile.

La decisione è prodotta prima di qualsiasi handoff.

La Migration 132 certifica la catena completa fino alla decisione di authorization e verifica:

- valutazioni persistenti;
- decisione immutabile;
- receipt ed eventi append-only;
- guard su plaintext ed endpoint;
- assenza di dispatch o risoluzione reale;
- rollback.

---

## 5.4 Authorization Handoff

La Migration 133 introduce il passaggio controllato dalla decisione di authorization a un manifest di handoff.

Il manifest:

```text
status=held
metadata_only=true
executable=false
```

Il livello conserva:

- request;
- idempotency;
- evaluation;
- decision;
- manifest;
- blocked attempt;
- receipt;
- event.

La Migration 134 certifica:

- authorization autorizzata;
- handoff accettato;
- manifest held;
- tentativo di esecuzione bloccato;
- replay;
- conflitto idempotente;
- immutabilità;
- neutralità;
- rollback.

---

## 5.5 Execution Permit

La Migration 135 introduce un permit logico che non costituisce una credenziale e non conferisce capacità esecutiva.

Proprietà certificate:

```text
metadata_only=true
executable=false
revocable=true
bearer_credential=false
transferable=false
execution_authorized=false
```

Il permit rappresenta l’esito governato della catena precedente, non un token utilizzabile.

La Migration 136 certifica:

- issuance;
- replay;
- conflitto;
- evaluation;
- decision;
- permit;
- expiry;
- revocation;
- blocked attempt;
- receipt ed eventi;
- rollback.

---

## 5.6 Dispatch Envelope

La Migration 137 introduce un envelope immutabile che raccoglie il lineage necessario per un eventuale futuro dispatch.

Proprietà:

```text
metadata_only=true
executable=false
dispatchable=false
transferable=false
queue_publishable=false
worker_claimable=false
dispatch_authorized=false
execution_authorized=false
```

L’envelope non può essere:

- pubblicato in coda;
- assegnato a un worker;
- claimed;
- inviato;
- eseguito.

La Migration 138 certifica:

- costruzione envelope;
- decisione;
- scadenza;
- cancellazione;
- tentativo bloccato;
- replay;
- guard;
- ricertificazione del permit;
- neutralità;
- rollback.

---

## 5.7 Dispatch Admission Ticket

La Migration 139 introduce l’ultimo gate passivo della catena.

Il ticket certifica che l’envelope ha superato le verifiche di admission senza renderlo operativo.

Proprietà:

```text
status=held_metadata_only
metadata_only=true
executable=false
publishable=false
leaseable=false
claimable=false
dispatchable=false
transferable=false
```

Autorizzazioni permanentemente negate:

```text
queue_publication_authorized=false
worker_claim_authorized=false
dispatch_authorized=false
execution_authorized=false
```

La Migration 140 certifica:

- richiesta admission;
- replay idempotente;
- conflitto bloccato;
- dieci valutazioni;
- decisione `ADMISSION_METADATA_APPROVED`;
- ticket held;
- blocked attempt;
- expiry;
- cancellation;
- read model;
- receipt;
- eventi;
- ricertificazione di envelope e permit;
- neutralità economica;
- rollback.

---

# 6. Contratto dati

Ogni livello segue uno schema coerente.

```text
policy
request
idempotency
evaluation/candidate
decision
domain artifact
attempt
receipt
event
read model
```

Gli artifact di dominio sono:

| Livello | Artifact |
|---|---|
| Registry | backend/version/capability/binding |
| Gateway | route manifest |
| Authorization | authorization decision |
| Handoff | handoff manifest |
| Permit | execution permit |
| Envelope | dispatch envelope |
| Admission | admission ticket |

La progressione non sostituisce il lineage precedente.

Ogni nuovo artifact dipende da oggetti già certificati.

---

# 7. Idempotenza e replay safety

I livelli dal Gateway in avanti utilizzano record di idempotenza dedicati.

La certificazione verifica due scenari distinti:

```text
stessa chiave + stesso payload
    → replay sicuro

stessa chiave + payload differente
    → conflitto bloccato
```

L’idempotenza impedisce:

- duplicazione di richieste;
- doppia emissione di artifact;
- divergenza silenziosa;
- riuso ambiguo della chiave;
- duplicazione di side effect futuri.

Il replay count viene esplicitamente verificato nelle lifecycle certification.

---

# 8. Immutabilità e append-only

Il sistema distingue:

## Oggetti immutabili

- policy certificate;
- versioni;
- capability;
- valutazioni;
- decisioni;
- manifest;
- permit;
- envelope;
- ticket.

## Oggetti append-only

- revoche;
- cancellazioni;
- tentativi;
- receipt;
- eventi.

I trigger impediscono update o delete incompatibili con il contratto.

Le lifecycle certification provano direttamente i guard tentando mutazioni non consentite.

---

# 9. Read model

Ogni foundation espone un read model dedicato:

```text
commercial_secret_backend_registry_read_model
commercial_secret_reference_gateway_read_model
commercial_secret_reference_authorization_read_model
commercial_secret_reference_authorization_handoff_read_model
commercial_secret_resolution_execution_permit_read_model
commercial_secret_resolution_dispatch_envelope_read_model
commercial_secret_resolution_dispatch_admission_read_model
```

I read model separano:

- strutture canoniche;
- scrittura governata;
- proiezione di lettura;
- stato effettivo derivato;
- lifecycle history.

La lettura non richiede modifiche dirette agli oggetti canonici.

---

# 10. Security Model

## 10.1 Row Level Security

Tutte le 63 tabelle introdotte dalle sette foundation hanno RLS abilitata.

Il sistema non si affida alla sola convenzione applicativa.

## 10.2 Privilegi

Le migration applicano una strategia esplicita:

```text
REVOKE
    ↓
GRANT selettivo
```

Sono state rilevate:

```text
121 istruzioni REVOKE
114 istruzioni GRANT
```

La quantità non costituisce da sola prova di sicurezza, ma conferma che il controllo dei privilegi è parte strutturale di ogni foundation.

## 10.3 Plaintext guard

Tutte le lifecycle certification verificano il divieto di memorizzare materiale sensibile in chiaro.

Il contratto è:

```text
opaque_references_only=true
plaintext_storage_forbidden=true
```

## 10.4 Endpoint guard

Il modello non consente l’introduzione di endpoint operativi nella catena passiva.

Sono vietati:

- host;
- URL utilizzabili;
- endpoint di rete;
- connection string;
- coordinate operative del backend.

## 10.5 Nessuna bearer credential

Permit, envelope e ticket non sono credenziali trasferibili.

```text
bearer_credential=false
transferable=false
```

---

# 11. Postura passiva certificata

L’intera catena mantiene disabilitate le capacità operative.

```text
automatic_dispatch_enabled=false
automatic_publication_enabled=false
queue_publication_enabled=false
runtime_job_creation_enabled=false
worker_lease_enabled=false
worker_claim_enabled=false
dispatch_enabled=false
execution_enabled=false
endpoint_discovery_enabled=false
backend_probe_enabled=false
backend_contact_enabled=false
backend_authentication_enabled=false
secret_lookup_enabled=false
secret_resolution_enabled=false
secret_decryption_enabled=false
credential_material_loading_enabled=false
credential_delivery_enabled=false
network_access_enabled=false
```

La presenza di nomi come permit, envelope o admission non implica capacità operative.

Essi rappresentano esclusivamente artifact di governance.

---

# 12. Neutralità commerciale e runtime

Ogni lifecycle certification misura i delta rispetto ai sistemi economici e operativi.

La Migration 140 ha ricertificato:

```text
purchase_delta=0
checkout_delta=0
provider_request_delta=0
callback_delta=0
reconciliation_delta=0
wallet_delta=0
ledger_delta=0
outbox_delta=0
```

Il blocco Secret Resolution:

- non crea acquisti;
- non apre checkout;
- non invia richieste a provider;
- non processa callback;
- non genera reconciliation;
- non accredita o consuma Pass;
- non modifica Wallet;
- non scrive nel Ledger;
- non pubblica outbox operative.

---

# 13. Certificazione transazionale

Le migration Lifecycle 128, 130, 132, 134, 136, 138 e 140:

1. aprono una transazione;
2. costruiscono una catena temporanea;
3. esercitano il lifecycle;
4. provano i guard;
5. verificano i conteggi;
6. verificano gli stati;
7. verificano i delta;
8. emettono notice di certificazione;
9. eseguono `ROLLBACK`.

Il risultato è una certificazione ripetibile senza persistenza di fixture di test.

La Migration 140 ha prodotto:

```text
MIGRATION_140_DISPATCH_ADMISSION_LIFECYCLE_CERTIFIED
MIGRATION_140_DISPATCH_ENVELOPE_LIFECYCLE_CERTIFIED
MIGRATION_140_PERMIT_LIFECYCLE_CERTIFIED
MIGRATION_140_CERTIFIED
MIGRATION_140_TRANSACTION_ROLLED_BACK
```

---

# 14. Analisi delle notice PostgreSQL

Durante l’esecuzione è stata osservata la notice:

```text
identifier "...evaluate_commercial_secret_resolution_dispatch_admission_request"
will be truncated
```

PostgreSQL limita gli identificatori a 63 byte.

La funzione è stata creata e richiamata coerentemente con il nome canonico troncato dal database.

La notice:

- non ha causato errore;
- non ha interrotto la migration;
- non ha alterato l’esito delle verifiche;
- non richiede una migration correttiva.

Raccomandazione futura: mantenere i nuovi identificatori sotto il limite per ridurre rumore operativo.

---

# 15. Threat Model sintetico

| Minaccia | Contromisura |
|---|---|
| Secret in chiaro | plaintext guard e riferimenti opachi |
| Endpoint operativo persistito | endpoint guard |
| Replay duplicato | idempotency record |
| Replay conflittuale | digest/payload conflict guard |
| Mutazione della decisione | trigger immutabile |
| Cancellazione della storia | append-only trigger |
| Permit usato come credenziale | bearer credential false |
| Trasferimento artifact | transferable false |
| Pubblicazione in coda | queue publication false |
| Worker claim | claimable false |
| Dispatch anticipato | dispatchable false |
| Esecuzione anticipata | executable false |
| Accesso non autorizzato | RLS, revoke, grant selettivi |
| Side effect economico | delta assertions |
| Fixture di certificazione persistenti | rollback finale |

---

# 16. Failure Model

Il sistema adotta il principio:

```text
fail closed
```

Una verifica non superata non degrada in autorizzazione parziale.

Le condizioni non conformi producono:

- decisione negativa;
- tentativo bloccato;
- receipt;
- evento;
- nessun artifact operativo;
- nessun side effect.

Expiry, revoca e cancellazione sono trattati come eventi espliciti e verificabili.

---

# 17. Provider Independence

La foundation non dipende da:

- AWS Secrets Manager;
- Google Secret Manager;
- Azure Key Vault;
- HashiCorp Vault;
- Supabase Vault;
- Stripe;
- PayPal;
- Mercado Pago;
- provider pubblicitari specifici.

Il backend registry descrive capability e riferimenti, non implementazioni proprietarie.

L’integrazione futura potrà utilizzare adapter senza modificare i contratti fondamentali della catena.

---

# 18. Limiti intenzionali

La foundation non implementa:

- connessioni di rete;
- lookup reale;
- autenticazione verso backend;
- decrypt;
- caricamento di credenziali;
- consegna di credenziali;
- code runtime;
- worker;
- lease;
- claim;
- dispatch;
- execution;
- rotazione reale dei secret;
- audit esterno del provider;
- sandbox E2E con secret manager reale.

Questi elementi sono esclusi intenzionalmente.

La loro assenza non costituisce debito della foundation, ma il confine certificato della fase.

---

# 19. Condizioni per una futura attivazione

Qualunque attivazione operativa dovrà essere una nuova fase autonoma.

Prerequisiti minimi:

1. scelta del secret manager;
2. adapter provider-specifico;
3. boundary di rete esplicito;
4. autenticazione workload-to-workload;
5. rotazione e revoca;
6. audit log esterno;
7. policy di least privilege;
8. sandbox isolata;
9. test di failure e timeout;
10. feature flag di attivazione;
11. rollout progressivo;
12. kill switch;
13. riconciliazione;
14. osservabilità;
15. nuova certificazione E2E.

Nessuna capability operativa deve essere aggiunta modificando silenziosamente le policy passive esistenti.

---

# 20. Findings

## Finding 1 — Catena completa

**Esito:** conforme.

Tutti i livelli previsti dal registry all’admission ticket sono presenti e collegati.

## Finding 2 — Coerenza Foundation/Lifecycle

**Esito:** conforme.

Ogni foundation dispone della relativa lifecycle certification.

## Finding 3 — RLS

**Esito:** conforme.

Tutte le 63 tabelle di foundation hanno RLS abilitata.

## Finding 4 — Immutabilità e append-only

**Esito:** conforme.

Sono presenti trigger dedicati e guard esercitati nelle certificazioni.

## Finding 5 — Idempotenza

**Esito:** conforme.

Replay sicuro e conflitto vengono distinti e certificati.

## Finding 6 — Plaintext ed endpoint

**Esito:** conforme.

Le lifecycle certification verificano i relativi guard.

## Finding 7 — Postura passiva

**Esito:** conforme.

Nessuna capability operativa risulta autorizzata.

## Finding 8 — Neutralità economica

**Esito:** conforme.

Tutti i delta certificati sono pari a zero.

## Finding 9 — Rollback

**Esito:** conforme.

Tutte le lifecycle certification terminano con rollback.

## Finding 10 — Naming PostgreSQL

**Esito:** osservazione non bloccante.

Un identificatore supera il limite PostgreSQL ed è troncato automaticamente. Il comportamento è coerente e già verificato in esecuzione.

---

# 21. Decisione sull’eventuale hotfix

L’audit non ha individuato difetti strutturali, di sicurezza o di lifecycle che richiedano una Migration 141.

La notice di truncation:

- è deterministica;
- non genera collisioni rilevate nel perimetro;
- non modifica il contratto;
- non impedisce l’esecuzione;
- non giustifica una migration correttiva isolata.

Decisione:

```text
MIGRATION_141_NOT_REQUIRED
```

---

# 22. Production Readiness

La foundation è considerata production-ready esclusivamente nel proprio perimetro:

```text
governance metadata
policy evaluation
lineage
idempotency
immutability
audit trail
passive lifecycle
```

Non è production-ready per la risoluzione reale dei secret, perché tale capacità non è ancora implementata e rimane intenzionalmente vietata.

La formulazione corretta è:

```text
Production-ready passive foundation
Not activated for external secret execution
```

---

# 23. Certificazione finale

Il presente audit certifica che le Migration 127–140 costituiscono una foundation unitaria, coerente e chiusa.

Stato finale:

```text
Backend Registry                       CERTIFIED
Reference Resolution Gateway           CERTIFIED
Policy Scope Enforcement               CERTIFIED
Authorization Handoff                  CERTIFIED
Execution Permit                       CERTIFIED
Dispatch Envelope                      CERTIFIED
Dispatch Admission Ticket              CERTIFIED

RLS                                    CERTIFIED
Idempotency                            CERTIFIED
Replay conflict protection             CERTIFIED
Immutability                           CERTIFIED
Append-only history                    CERTIFIED
Plaintext protection                   CERTIFIED
Endpoint protection                    CERTIFIED
Passive posture                        CERTIFIED
Commercial neutrality                  CERTIFIED
Transactional rollback                 CERTIFIED
Provider independence                  CERTIFIED
```

Verdetto:

```text
FANTAGOL_COMMERCIAL_SECRET_RESOLUTION_PASSIVE_FOUNDATION_CERTIFIED
```

La costruzione tecnica e l’audit architetturale della fase sono conclusi.

La fase potrà essere chiusa operativamente dopo:

```text
1. inserimento del presente documento in docs/architecture
2. commit e push
3. verifica repository clean
4. checkpoint operativo finale
```
