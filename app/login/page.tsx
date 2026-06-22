import Header from "../../components/Header";

export default function LoginPage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f1f1f] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-green-500">
            FantaGol
          </p>

          <h1 className="mb-3 text-3xl font-black">
            Accedi al tuo account
          </h1>

          <p className="mb-8 text-gray-400">
            Entra nelle tue leghe, crea nuove sfide e gestisci i tuoi pronostici.
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
              type="email"
              placeholder="Email"
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-green-500"
            />

            <input
              type="password"
              placeholder="Password"
              className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-green-500"
            />

            <button
              type="submit"
              className="w-full rounded-xl bg-gradient-to-r from-green-700 to-green-600 px-5 py-3 font-semibold text-white transition hover:from-green-600 hover:to-green-500"
            >
              Accedi
            </button>
          </form>

          <p className="mt-6 text-center text-sm text-gray-400">
            Non hai un account?{" "}
            <a href="/registrati" className="font-semibold text-green-400 hover:text-green-300">
              Registrati
            </a>
          </p>
        </div>
      </section>
    </main>
  );
}