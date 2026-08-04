"use client";

import { useParams, useRouter } from "next/navigation";

import DashboardCard from "../../../../../components/ui/DashboardCard";

export default function AdminGuidePage() {
  const params = useParams<{ id: string }>();
  const router = useRouter();

  return (
    <main className="min-h-[calc(100vh-3.5rem)] bg-black text-white">
      <section className="mx-auto max-w-4xl px-4 py-6 sm:py-8">
        <button
          type="button"
          onClick={() =>
            router.push(`/leghe/${params.id}/impostazioni`)
          }
          className="mb-5 inline-flex items-center gap-2 rounded-xl border border-white/10 px-4 py-2 text-sm font-black text-gray-300 transition hover:border-[#A6E824]/50 hover:text-[#A6E824]"
        >
          <span aria-hidden="true">&lsaquo;</span>
          Torna alle Impostazioni
        </button>

        <DashboardCard className="border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] shadow-2xl shadow-black/70">
          <p className="text-xs font-black uppercase tracking-[0.22em] text-[#A6E824]">
            Guida Admin
          </p>

          <h1 className="mt-3 text-[clamp(1.45rem,6.2vw,2.25rem)] font-black leading-tight sm:text-4xl">
            <span className="block sm:inline">Mansioni</span>{" "}
            <span className="whitespace-nowrap">
              dell&apos;Amministratore
            </span>
          </h1>

          <p className="mt-4 text-sm font-semibold leading-7 text-gray-300 sm:text-base">
            L&apos;Amministratore è il responsabile della gestione della
            lega. Ha il compito di configurare la competizione, amministrare
            i partecipanti e prendere le decisioni previste dal regolamento
            quando si verificano situazioni particolari.
          </p>

          <p className="mt-3 text-sm font-semibold leading-7 text-gray-400 sm:text-base">
            Tutte le operazioni amministrative vengono registrate
            automaticamente nel Giornale di Bordo della lega, consultabile
            da tutti i partecipanti.
          </p>
        </DashboardCard>

        <GuideSection title="Gestione della lega">
          <GuideList
            items={[
              "Creare una lega privata.",
              "Creare una lega pubblica.",
              "Scegliere il numero massimo di partecipanti per una lega pubblica.",
              "Chiudere le iscrizioni. Alla chiusura FantaGol genera o rigenera automaticamente i calendari oppure mantiene quelli esistenti quando consentito.",
              "Riaprire le iscrizioni fino al primo calcio d'inizio utile per il calcolo dei risultati.",
              "Eliminare definitivamente la lega.",
            ]}
          />
        </GuideSection>

        <GuideSection title="Gestione dei partecipanti">
          <GuideList
            items={[
              "Rimuovere un partecipante dalla lega.",
              "Indicare il motivo della rimozione.",
              "Riammettere un partecipante precedentemente rimosso.",
              "Gestire il rientro di un partecipante che aveva già fatto parte della lega.",
            ]}
          />
        </GuideSection>

        <GuideSection title="Gestione del Vice">
          <GuideList
            items={[
              "Nominare un Vice.",
              "Sostituire il Vice nominando un altro partecipante.",
            ]}
          />
        </GuideSection>

        <GuideSection title="Bonus e malus">
          <GuideList
            items={[
              "Attivare o disattivare il bonus Sorpresa.",
              "Attivare o disattivare il bonus Gol Show.",
              "Attivare o disattivare il bonus Grande Slam.",
              "Attivare o disattivare il malus Cantonata.",
              "Attivare o disattivare il malus Segno Opposto.",
              "Indicare il motivo della modifica.",
            ]}
          />

          <InfoBox>
            La disattivazione del bonus Gol Show comporta automaticamente
            anche la disattivazione del bonus Grande Slam.
          </InfoBox>
        </GuideSection>

        <GuideSection title="Recupero dei pronostici">
          <p className="text-sm font-semibold leading-7 text-gray-300 sm:text-base">
            L&apos;Amministratore può autorizzare eccezionalmente un
            partecipante a recuperare i pronostici non inseriti prima di un
            anticipo.
          </p>

          <p className="mt-3 text-sm font-semibold leading-7 text-gray-400 sm:text-base">
            La riapertura è limitata esclusivamente ai pronostici mancanti
            delle partite non ancora iniziate e rimane disponibile soltanto
            fino al successivo calcio d&apos;inizio utile.
          </p>
        </GuideSection>

        <GuideSection title="Gestione delle partite rinviate o sospese">
          <p className="text-sm font-semibold leading-7 text-gray-300 sm:text-base">
            Prima che si verifichi un rinvio, l&apos;Amministratore può
            scegliere come la lega dovrà gestire questo tipo di evento.
          </p>

          <div className="mt-5 space-y-3">
            <PolicyBlock title="Attendere il recupero e mantenere i pronostici">
              La partita resta valida e i pronostici già inseriti rimangono
              acquisiti e non modificabili.
            </PolicyBlock>

            <PolicyBlock title="Attendere il recupero e riaprire i pronostici">
              La partita resta valida e soltanto i pronostici relativi al
              recupero potranno essere inseriti o modificati fino al nuovo
              calcio d&apos;inizio.
            </PolicyBlock>

            <PolicyBlock title="Escludere la partita dalla giornata">
              La partita viene esclusa dal calcolo e la giornata può essere
              certificata senza attendere il recupero.
            </PolicyBlock>
          </div>

          <p className="mt-5 text-sm font-semibold leading-7 text-gray-400 sm:text-base">
            L&apos;Amministratore può modificare questa impostazione in
            qualsiasi momento per adattarla alle esigenze della lega. Se una
            partita rinviata è già in gestione, il cambio di modalità
            richiederà una conferma prima di essere applicato.
            L&apos;esclusione già applicata a una singola partita è
            irreversibile.
          </p>
        </GuideSection>

        <GuideSection title="Trasferimento e continuità dell'amministrazione">
          <GuideList
            items={[
              "Trasferire volontariamente l'amministrazione a un altro partecipante idoneo.",
              "Prima di abbandonare la lega, nominare un nuovo Amministratore quando sono presenti altri partecipanti.",
              "In caso di inattività, abbandono della lega o cancellazione dell'account, lasciare che FantaGol assegni automaticamente il ruolo a un altro partecipante secondo le regole previste.",
            ]}
          />
        </GuideSection>

        <DashboardCard className="mt-6 border-[#A6E824]/25">
          <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
            Trasparenza amministrativa
          </p>

          <h2 className="mt-2 text-2xl font-black">
            Giornale di Bordo
          </h2>

          <p className="mt-4 text-sm font-semibold leading-7 text-gray-300 sm:text-base">
            Tutte le operazioni amministrative effettuate nella lega vengono
            registrate automaticamente nel Giornale di Bordo.
          </p>

          <p className="mt-3 text-sm font-semibold leading-7 text-gray-400 sm:text-base">
            Il registro è consultabile da tutti i partecipanti e garantisce
            trasparenza nella gestione della competizione.
          </p>
        </DashboardCard>
      </section>
    </main>
  );
}

function GuideSection({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <DashboardCard className="mt-6">
      <h2 className="text-2xl font-black">{title}</h2>
      <div className="mt-4">{children}</div>
    </DashboardCard>
  );
}

function GuideList({ items }: { items: string[] }) {
  return (
    <ul className="space-y-3">
      {items.map((item) => (
        <li
          key={item}
          className="flex items-start gap-3 text-sm font-semibold leading-7 text-gray-300 sm:text-base"
        >
          <span
            aria-hidden="true"
            className="mt-[0.65rem] h-2 w-2 shrink-0 rounded-full bg-[#A6E824]"
          />
          <span>{item}</span>
        </li>
      ))}
    </ul>
  );
}

function InfoBox({ children }: { children: React.ReactNode }) {
  return (
    <div className="mt-5 rounded-2xl border border-[#A6E824]/20 bg-[#A6E824]/5 p-4 text-sm font-semibold leading-6 text-[#D9FF82]">
      {children}
    </div>
  );
}

function PolicyBlock({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <h3 className="font-black text-white">{title}</h3>
      <p className="mt-2 text-sm font-semibold leading-6 text-gray-400">
        {children}
      </p>
    </div>
  );
}
