export default function Home() {
  return (
    <main className="min-h-screen bg-black text-white">
      <section className="max-w-6xl mx-auto px-6 py-24 text-center">
        <h1 className="text-6xl font-bold mb-6">
          FantaGol
        </h1>

        <p className="text-2xl text-gray-400 mb-10">
          La nuova generazione del fantasy pronostici.
        </p>

        <div className="flex flex-col md:flex-row gap-4 justify-center">
          <a
            href="/play"
            className="px-8 py-4 bg-white text-black rounded-xl font-semibold"
          >
            Gioca Online
          </a>

          <a
            href="/download"
            className="px-8 py-4 border border-gray-600 rounded-xl"
          >
            Scarica l'App
          </a>
        </div>
      </section>

      <section className="max-w-6xl mx-auto px-6 py-20">
        <h2 className="text-4xl font-bold mb-12 text-center">
          Come Funziona
        </h2>

        <div className="grid md:grid-cols-3 gap-8">
          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              1. Entra in una Lega
            </h3>
            <p className="text-gray-400">
              Sfida amici, colleghi o familiari.
            </p>
          </div>

          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              2. Inserisci i Pronostici
            </h3>
            <p className="text-gray-400">
              Prevedi i risultati delle partite.
            </p>
          </div>

          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              3. Vinci la Giornata
            </h3>
            <p className="text-gray-400">
              Accumula punti e scala la classifica.
            </p>
          </div>
        </div>
      </section>

      <section className="max-w-6xl mx-auto px-6 py-20">
        <h2 className="text-4xl font-bold mb-12 text-center">
          Modalità di Gioco
        </h2>

        <div className="grid md:grid-cols-3 gap-8">
          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              Fantacalcio
            </h3>
            <p className="text-gray-400">
              Sistema punti avanzato con bonus e malus.
            </p>
          </div>

          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              One-to-One
            </h3>
            <p className="text-gray-400">
              Sfide dirette contro un avversario.
            </p>
          </div>

          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              Punti Puri
            </h3>
            <p className="text-gray-400">
              Classifica basata esclusivamente sui punti.
            </p>
          </div>
        </div>
      </section>

      <footer className="border-t border-gray-800 py-10 text-center text-gray-500">
        © 2026 FantaGol.app
      </footer>
    </main>
  )
}