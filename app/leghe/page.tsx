import Header from "../../components/Header";

export default function LeghePage() {
  const leghe = [
    {
      nome: "FantaGol Serie A",
      partecipanti: 12,
      giornata: 6,
      modalita: "Fantacalcio • One-to-One • Punti Puri",
      stato: "Pronostici aperti",
    },
    {
      nome: "Amici del Bar",
      partecipanti: 8,
      giornata: 3,
      modalita: "Punti Puri",
      stato: "Giornata in corso",
    },
  ];

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto max-w-6xl px-6 py-16">
        <div className="mb-10">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            Home Utente
          </p>

          <h1 className="text-4xl font-black">
            Le mie Leghe
          </h1>

          <p className="mt-3 max-w-2xl text-gray-400">
            Scegli la lega in cui vuoi entrare oppure creane una nuova e invita i tuoi amici.
          </p>
        </div>

        <div className="mb-10 grid gap-4 md:grid-cols-2">
          <a
            href="/crea-lega"
            className="rounded-2xl bg-[#A6E824] p-6 font-bold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
          >
            + Crea Lega
          </a>

          <a
            href="/invito/FG-ABCD1234"
            className="rounded-2xl border border-[#A6E824]/50 bg-[#111111] p-6 font-bold text-[#A6E824] transition hover:border-[#A6E824]"
          >
            Hai ricevuto un invito?
          </a>
        </div>

        <div className="space-y-5">
          {leghe.map((lega) => (
            <a
              key={lega.nome}
              href="/leghe/fantagol-serie-a"
              className="block rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6 shadow-xl shadow-black/50 transition hover:border-[#A6E824]/60"
            >
              <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
                <div>
                  <h2 className="text-2xl font-black">{lega.nome}</h2>

                  <p className="mt-2 text-sm text-gray-400">
                    {lega.partecipanti} partecipanti • Giornata {lega.giornata}
                  </p>

                  <p className="mt-2 text-sm text-gray-500">
                    {lega.modalita}
                  </p>
                </div>

                <div className="rounded-full border border-[#A6E824]/40 px-4 py-2 text-sm font-semibold text-[#A6E824]">
                  {lega.stato}
                </div>
              </div>
            </a>
          ))}
        </div>
      </section>
    </main>
  );
}