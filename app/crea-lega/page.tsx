import Header from "../../components/Header";

export default function CreaLegaPage() {
  const inviteLink = "https://fantagol.app/invito/FG-ABCD1234";

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-xl rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            Nuova Lega
          </p>

          <h1 className="mb-3 text-3xl font-black">
            Crea la tua lega
          </h1>

          <p className="mb-8 text-gray-400">
            Dai un nome alla lega e genera un link invito da condividere con i partecipanti.
          </p>

          <form className="space-y-5">
            <div>
              <label className="mb-2 block text-sm font-semibold text-gray-300">
                Nome lega
              </label>
              <input
                type="text"
                placeholder="Es. Amici del Bar"
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
              />
            </div>

            <button
              type="button"
              className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
            >
              Crea Lega
            </button>
          </form>

          <div className="mt-8 rounded-2xl border border-gray-700 bg-[#111111] p-5">
            <p className="mb-2 text-sm font-semibold text-gray-300">
              Link invito generato
            </p>

            <div className="rounded-xl border border-gray-700 bg-black px-4 py-3 text-sm text-gray-300">
              {inviteLink}
            </div>

            <button className="mt-4 w-full rounded-xl border border-[#A6E824]/50 px-5 py-3 font-semibold text-[#A6E824] transition hover:border-[#A6E824]">
              Copia Link
            </button>
          </div>
        </div>
      </section>
    </main>
  );
}