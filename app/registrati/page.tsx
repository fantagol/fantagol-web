import Header from "../../components/Header";

export default function RegistratiPage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            FantaGol
          </p>

          <h1 className="mb-3 text-3xl font-black">
            Crea il tuo account
          </h1>

          <p className="mb-8 text-gray-400">
            Registrati per creare leghe, ricevere inviti e iniziare a giocare.
          </p>

          <button className="mb-6 w-full rounded-xl border border-gray-600 bg-white px-5 py-3 font-semibold text-black transition hover:bg-gray-200">
            Continua con Google
          </button>

          <div className="mb-6 flex items-center gap-4 text-sm text-gray-500">
            <div className="h-px flex-1 bg-gray-700" />
            oppure
            <div className="h-px flex-1 bg-gray-700" />
          </div>

          <form className="space-y-4">
            <input
              type="text"
              placeholder="Nome utente"
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <input
              type="email"
              placeholder="Email"
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <input
              type="password"
              placeholder="Password"
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
            />

            <button
              type="submit"
              className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
            >
              Registrati
            </button>
          </form>

          <p className="mt-6 text-center text-sm text-gray-400">
            Hai già un account?{" "}
            <a href="/login" className="font-semibold text-[#A6E824] hover:brightness-110">
              Accedi
            </a>
          </p>
        </div>
      </section>
    </main>
  );
}