/* eslint-disable react/no-unescaped-entities */
import Header from "../../components/Header";

export const metadata = {
  title: "Privacy Policy | FantaGol",
  description:
    "Informativa sulla privacy e sul trattamento dei dati personali in FantaGol.",
};

const sections = [
  {
    title: "1. Informazioni raccolte",
    body: (
      <>
        <p>
          FantaGol raccoglie e tratta i dati necessari per fornire il
          servizio, gestire gli account e consentire la partecipazione alle
          funzionalità del gioco.
        </p>
        <p>
          I dati possono comprendere nome o nome visualizzato, indirizzo
          email, identificativo utente, informazioni relative all'attività
          nell'app, pronostici e altri contenuti generati dall'utente,
          immagini caricate volontariamente, cronologia delle transazioni o
          degli acquisti e informazioni tecniche necessarie al funzionamento
          e alla sicurezza del servizio.
        </p>
      </>
    ),
  },
  {
    title: "2. Finalità del trattamento",
    body: (
      <>
        <p>I dati vengono utilizzati principalmente per:</p>
        <ul className="mt-3 list-disc space-y-2 pl-6">
          <li>creare, autenticare e gestire l'account FantaGol;</li>
          <li>fornire le funzionalità del gioco e delle leghe;</li>
          <li>registrare pronostici, classifiche, risultati e storico competitivo;</li>
          <li>gestire profilo, avatar e contenuti caricati dall'utente;</li>
          <li>gestire Premium Pass, transazioni e funzionalità commerciali;</li>
          <li>prevenire frodi, abusi e utilizzi non autorizzati;</li>
          <li>garantire sicurezza, integrità e conformità del servizio;</li>
          <li>fornire assistenza agli utenti.</li>
        </ul>
      </>
    ),
  },
  {
    title: "3. Pubblicità e identificativi del dispositivo",
    body: (
      <>
        <p>
          L'app Android integra servizi Google per la pubblicità e, in
          particolare, funzionalità pubblicitarie Rewarded.
        </p>
        <p>
          I servizi Google Mobile Ads possono trattare identificativi del
          dispositivo o altri identificativi, informazioni tecniche e dati
          necessari alla fornitura, misurazione, sicurezza e prevenzione
          delle frodi relative alla pubblicità.
        </p>
        <p>
          La disponibilità di un video Rewarded non comporta l'obbligo per
          l'utente di visualizzarlo. Alcuni componenti tecnici del servizio
          pubblicitario possono tuttavia essere inizializzati dall'app prima
          della scelta di visualizzare un annuncio.
        </p>
      </>
    ),
  },
  {
    title: "4. Foto e contenuti generati dagli utenti",
    body: (
      <>
        <p>
          Gli utenti possono scegliere di fornire immagini e altri contenuti
          nell'ambito delle funzionalità che li prevedono. Questi dati sono
          facoltativi quando la relativa funzionalità può essere utilizzata
          senza il loro caricamento.
        </p>
        <p>
          I pronostici, le scelte di gioco e gli altri contenuti generati
          dall'utente vengono trattati per consentire il funzionamento delle
          competizioni, delle classifiche e dello storico FantaGol.
        </p>
      </>
    ),
  },
  {
    title: "5. Acquisti e informazioni finanziarie",
    body: (
      <>
        <p>
          FantaGol può conservare la cronologia delle transazioni, degli
          acquisti e dei Premium Pass quando necessaria al funzionamento del
          servizio, alla sicurezza, alla prevenzione delle frodi e agli
          obblighi applicabili.
        </p>
        <p>
          Gli eventuali dati completi dello strumento di pagamento sono
          gestiti dal fornitore di pagamento applicabile e non vengono
          conservati direttamente da FantaGol salvo quanto strettamente
          necessario per registrare l'esito e la prova della transazione.
        </p>
      </>
    ),
  },
  {
    title: "6. Fornitori e destinatari",
    body: (
      <>
        <p>
          FantaGol utilizza fornitori tecnici necessari all'erogazione del
          servizio, inclusi servizi di infrastruttura, autenticazione,
          database, hosting e servizi Google utilizzati dall'app Android.
        </p>
        <p>
          I dati vengono comunicati a terze parti soltanto quando necessario
          per fornire tali servizi, rispettare obblighi applicabili,
          proteggere FantaGol o gli utenti, oppure quando richiesto dalla
          legge.
        </p>
      </>
    ),
  },
  {
    title: "7. Sicurezza",
    body: (
      <>
        <p>
          I dati trasmessi tra l'app, il sito e i servizi backend vengono
          trasferiti mediante connessioni protette. FantaGol applica misure
          tecniche e organizzative finalizzate a limitare l'accesso ai dati,
          proteggere gli account e preservare l'integrità del servizio.
        </p>
      </>
    ),
  },
  {
    title: "8. Conservazione dei dati",
    body: (
      <>
        <p>
          I dati personali diretti vengono conservati per il tempo necessario
          a fornire il servizio e per le finalità per cui sono stati raccolti,
          salvo periodi ulteriori richiesti da obblighi legali, fiscali,
          sicurezza, prevenzione delle frodi o tutela di diritti.
        </p>
        <p>
          Le evidenze economiche e le informazioni soggette a conservazione
          ristretta vengono riesaminate dopo 5 anni e, in condizioni
          ordinarie, non vengono conservate oltre 10 anni, salvo obblighi
          legali o regolatori che richiedano un periodo più lungo.
        </p>
      </>
    ),
  },
  {
    title: "9. Eliminazione dell'account",
    body: (
      <>
        <p>
          L'utente può richiedere l'eliminazione del proprio account
          direttamente tramite la procedura dedicata di FantaGol.
        </p>
        <p>
          A seguito dell'eliminazione, i dati personali diretti vengono
          eliminati, lo storico competitivo viene anonimizzato e le evidenze
          economiche o di integrità che devono essere mantenute vengono
          conservate esclusivamente in forma ristretta o pseudonimizzata,
          secondo le regole applicabili.
        </p>
        <a
          href="/elimina-account"
          className="mt-4 inline-flex rounded-xl bg-[#A6E824] px-5 py-3 font-black text-black"
        >
          Gestisci eliminazione account
        </a>
      </>
    ),
  },
  {
    title: "10. Diritti e assistenza",
    body: (
      <>
        <p>
          Per richieste relative ai propri dati, alla privacy o
          all'esercizio dei diritti applicabili, l'utente può utilizzare il
          canale di Supporto FantaGol.
        </p>
        <a
          href="/supporto"
          className="mt-4 inline-flex rounded-xl border border-white/15 px-5 py-3 font-black text-white"
        >
          Vai al Supporto
        </a>
      </>
    ),
  },
  {
    title: "11. Aggiornamenti dell'informativa",
    body: (
      <>
        <p>
          Questa informativa può essere aggiornata quando cambiano le
          funzionalità del servizio, i trattamenti effettuati o gli obblighi
          applicabili. La versione pubblicata su questa pagina rappresenta
          l'informativa corrente.
        </p>
      </>
    ),
  },
];

export default function PrivacyPage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <div className="mx-auto max-w-4xl px-5 pb-20 pt-24">
        <section className="rounded-3xl border border-[#A6E824]/25 bg-gradient-to-b from-[#172016] to-[#0d0d0d] p-6 shadow-2xl shadow-black/70 md:p-10">
          <p className="text-sm font-black uppercase tracking-[0.25em] text-[#A6E824]">
            Privacy
          </p>

          <h1 className="mt-4 text-4xl font-black md:text-5xl">
            Informativa sulla privacy
          </h1>

          <p className="mt-4 text-sm text-gray-400">
            Ultimo aggiornamento: 20 agosto 2026
          </p>

          <p className="mt-5 max-w-3xl text-base leading-7 text-gray-300">
            Questa informativa descrive come FantaGol raccoglie, utilizza,
            protegge e conserva i dati degli utenti quando utilizzano il sito
            web e l'app Android FantaGol.
          </p>
        </section>

        <div className="mt-8 space-y-5">
          {sections.map((section) => (
            <section
              key={section.title}
              className="rounded-2xl border border-white/10 bg-[#111417] p-6"
            >
              <h2 className="text-xl font-black text-white">
                {section.title}
              </h2>

              <div className="mt-3 space-y-3 text-sm leading-6 text-gray-300">
                {section.body}
              </div>
            </section>
          ))}
        </div>

        <section className="mt-8 rounded-2xl border border-white/10 bg-[#111417] p-6 text-sm leading-6 text-gray-400">
          <strong className="text-white">FantaGol</strong>
          <br />
          Per richieste sulla privacy utilizza la pagina Supporto disponibile
          sul sito e nell'app.
        </section>
      </div>
    </main>
  );
}