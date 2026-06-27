import Header from "../../../components/Header";

export default function LegaHomePage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto max-w-6xl px-6 py-16">
        <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
          Ultima lega usata
        </p>

        <h1 className="text-4xl font-black">FantaGol Serie A</h1>

        <p className="mt-3 text-gray-400">
          12 partecipanti • Giornata 6 • Sei amministratore
        </p>

        <div className="mt-10 grid gap-5 md:grid-cols-3">
          <a href="/play" className="rounded-3xl bg-[#A6E824] p-6 font-black text-black">
            Pronostica
          </a>

          <a href="/leghe" className="rounded-3xl border border-gray-700 bg-[#1f2427] p-6 font-bold text-white">
            Cambia Lega
          </a>

          <a href="/crea-lega" className="rounded-3xl border border-[#A6E824]/50 bg-[#111111] p-6 font-bold text-[#A6E824]">
            Invita Partecipanti
          </a>
        </div>

        <div className="mt-10 grid gap-5 md:grid-cols-3">
          <div className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6">
            <h2 className="text-xl font-black">Fantacalcio</h2>
            <p className="mt-2 text-gray-400">Classifica e risultati modalità principale.</p>
          </div>

          <div className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6">
            <h2 className="text-xl font-black">One-to-One</h2>
            <p className="mt-2 text-gray-400">Sfide dirette e calendario H2H.</p>
          </div>

          <div className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6">
            <h2 className="text-xl font-black">Punti Puri</h2>
            <p className="mt-2 text-gray-400">Somma punti generale senza conversione.</p>
          </div>
        </div>
      </section>
    </main>
  );
}