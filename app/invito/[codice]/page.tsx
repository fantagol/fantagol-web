import Header from "../../../components/Header";

export default function InvitoPage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-lg rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 text-center shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            Invito Lega
          </p>

          <h1 className="mb-3 text-3xl font-black">
            Sei stato invitato in una lega
          </h1>

          <p className="mb-8 text-gray-400">
            Accedi o registrati per entrare automaticamente nella lega FantaGol condivisa dall&apos;admin.
          </p>

          <div className="mb-8 rounded-2xl border border-gray-700 bg-[#111111] p-5 text-left">
            <p className="text-sm text-gray-400">Codice invito</p>
            <p className="mt-1 text-xl font-black text-[#A6E824]">
              FG-ABCD1234
            </p>
          </div>

          <div className="flex flex-col gap-4">
            <a
              href="/login"
              className="rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
            >
              Accedi e unisciti
            </a>

            <a
              href="/registrati"
              className="rounded-xl border border-[#A6E824]/50 px-5 py-3 font-semibold text-[#A6E824] transition hover:border-[#A6E824]"
            >
              Registrati e unisciti
            </a>
          </div>
        </div>
      </section>
    </main>
  );
}