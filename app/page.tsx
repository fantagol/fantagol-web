import Header from "../components/Header";

export default function Home() {
  return (
    <main className="min-h-screen overflow-hidden bg-black text-white">
      <Header />

      <section className="relative mx-auto flex min-h-[calc(100vh-72px)] max-w-6xl flex-col items-center justify-center px-6 text-center">
        <div className="absolute left-1/2 top-1/2 z-0 h-96 w-96 -translate-x-1/2 -translate-y-1/2 rounded-full bg-[#A6E824]/10 blur-3xl" />
        <div className="absolute right-10 top-24 z-0 h-64 w-64 rounded-full bg-[#A6E824]/5 blur-3xl" />
        <div className="absolute bottom-10 left-10 z-0 h-56 w-56 rounded-full bg-white/5 blur-3xl" />

        <div className="relative z-10">
          <p className="mb-6 text-sm font-semibold uppercase tracking-[0.35em] text-[#A6E824]">
            L&apos;APP DEL FANTAPRONOSTICO
          </p>

          <h1 className="mb-6 text-6xl font-black md:text-7xl">
            FantaGol
          </h1>

          <p className="mx-auto mb-10 max-w-3xl text-2xl font-medium text-gray-300">
            Un solo pronostico.
            <br />
            Tre modalita di gioco.
            <br />
            Infinite sfide.
          </p>

          <div className="flex flex-col justify-center gap-4 md:flex-row">
            <a
              href="/login"
              className="rounded-xl bg-white px-8 py-4 font-semibold text-black shadow-xl shadow-white/10 transition hover:scale-105"
            >
              Gioca Online
            </a>

            <a
              href="/download"
              className="rounded-xl border border-[#A6E824]/50 bg-green-950/30 px-8 py-4 font-semibold text-[#A6E824] transition hover:border-[#A6E824] hover:bg-green-900/40"
            >
              Scarica l&apos;App
            </a>
          </div>

          <a
            href="/regolamento"
            className="mt-6 inline-block text-sm font-semibold text-[#A6E824] hover:brightness-110"
          >
            Come si Gioca &gt;
          </a>
        </div>
      </section>
    </main>
  );
}