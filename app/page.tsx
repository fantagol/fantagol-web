export default function Home() {
  return (
    <main className="min-h-screen bg-black text-white">
      <header className="border-b border-gray-800">
        <div className="max-w-6xl mx-auto px-6 h-20 flex items-center justify-between">
          <div className="text-3xl font-black">
            FantaGol
          </div>

          <nav className="hidden md:flex gap-8 text-gray-300">
            <a href="#funziona">Come Funziona</a>
            <a href="#modalita">Modalità</a>
            <a href="#perche">Perché FantaGol</a>
            <a href="/play">Play Online</a>
            <a href="/download">Download</a>
          </nav>
        </div>
      </header>

      <section className="max-w-6xl mx-auto px-6 py-24 text-center">
        <p className="text-sm uppercase tracking-[0.35em] text-gray-500 mb-6">
          Fantasy pronostici • live score • sfide tra amici
        </p>

        <h1 className="text-6xl md:text-7xl font-black mb-6">
          FantaGol
        </h1>

        <p className="text-2xl text-gray-400 mb-10 max-w-3xl mx-auto">
          Pronostica le partite, segui i risultati live e sfida la tua lega
          in più modalità di gioco.
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
            Scarica l&apos;App
          </a>
        </div>
      </section>

      <section
        id="funziona"
        className="max-w-6xl mx-auto px-6 py-20"
      >
        <h2 className="text-4xl font-bold mb-12 text-center">
          Come Funziona
        </h2>

        <div className="grid md:grid-cols-3 gap-8">
          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              1. Pronostica i risultati
            </h3>

            <p className="text-gray-400">
              Inserisci il risultato esatto delle partite della giornata.
              Bastano due numeri per ogni match.
            </p>
          </div>

          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              2. Segui i punti live
            </h3>

            <p className="text-gray-400">
              Durante le partite, risultati e punteggi si aggiornano:
              ogni gol può cambiare la classifica.
            </p>
          </div>

          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              3. Sfida la tua lega
            </h3>

            <p className="text-gray-400">
              Competi con amici e avversari in classifiche generali,
              sfide dirette e modalità dedicate.
            </p>
          </div>
        </div>
      </section>

      <section
        id="modalita"
        className="max-w-6xl mx-auto px-6 py-20"
      >
        <h2 className="text-4xl font-bold mb-4 text-center">
          Modalità di Gioco
        </h2>

        <p className="text-gray-400 text-center mb-12 max-w-3xl mx-auto">
          Una sola piattaforma, più modi di vivere la giornata:
          puoi giocare con una modalità oppure combinarle nella stessa lega.
        </p>

        <div className="grid md:grid-cols-3 gap-8">
          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              Fantacalcio
            </h3>

            <p className="text-gray-400">
              Sistema punti avanzato basato sulla precisione dei pronostici,
              con bonus e malus configurabili.
            </p>
          </div>

          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              One-to-One
            </h3>

            <p className="text-gray-400">
              Ogni giornata diventa una sfida diretta contro un avversario:
              vince chi totalizza più punti nel turno.
            </p>
          </div>

          <div className="p-6 border border-gray-800 rounded-2xl">
            <h3 className="text-2xl font-semibold mb-3">
              Punti Puri
            </h3>

            <p className="text-gray-400">
              Classifica generale trasparente, basata esclusivamente
              sui punti ottenuti giornata dopo giornata.
            </p>
          </div>
        </div>
      </section>

      <section
        id="perche"
        className="max-w-6xl mx-auto px-6 py-20"
      >
        <h2 className="text-4xl font-bold mb-12 text-center">
          Perché FantaGol?
        </h2>

        <div className="grid md:grid-cols-2 gap-6">
          <div className="p-6 bg-gray-950 border border-gray-800 rounded-2xl">
            Risultati live e classifiche automatiche
          </div>

          <div className="p-6 bg-gray-950 border border-gray-800 rounded-2xl">
            Pronostici semplici: solo risultato casa-trasferta
          </div>

          <div className="p-6 bg-gray-950 border border-gray-800 rounded-2xl">
            Web app giocabile da browser, PC e smartphone
          </div>

          <div className="p-6 bg-gray-950 border border-gray-800 rounded-2xl">
            App Android e iPhone in arrivo
          </div>

          <div className="p-6 bg-gray-950 border border-gray-800 rounded-2xl">
            Leghe private per gruppi di amici
          </div>

          <div className="p-6 bg-gray-950 border border-gray-800 rounded-2xl">
            Modalità indipendenti ma compatibili nella stessa stagione
          </div>
        </div>
      </section>

      <section className="max-w-6xl mx-auto px-6 py-24 text-center">
        <h2 className="text-4xl font-bold mb-6">
          Pronto a giocare?
        </h2>

        <p className="text-gray-400 mb-10">
          La versione online è in costruzione. I test iniziano con le prossime giornate.
        </p>

        <div className="flex flex-col md:flex-row gap-4 justify-center">
          <a
            href="/play"
            className="px-8 py-4 bg-white text-black rounded-xl font-semibold"
          >
            Vai alla Web App
          </a>

          <a
            href="/download"
            className="px-8 py-4 border border-gray-600 rounded-xl"
          >
            App Mobile
          </a>
        </div>
      </section>

      <footer className="border-t border-gray-800 py-10 text-center text-gray-500">
        © 2026 FantaGol.app
      </footer>
    </main>
  );
}