export default function RegolamentoPage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <div className="max-w-4xl mx-auto px-6 py-20">

        <h1 className="text-5xl font-black mb-6">
          Regolamento FantaGol
        </h1>

        <p className="text-xl text-gray-400 mb-16">
          Un solo pronostico. Tre modalità di gioco. Infinite sfide.
        </p>

        <section className="mb-16">
          <h2 className="text-3xl font-bold mb-6">
            Come si gioca
          </h2>

          <p className="text-gray-300 leading-8">
            Per ogni partita devi inserire un solo pronostico:
            il risultato esatto.
          </p>

          <div className="mt-4 p-4 border border-gray-800 rounded-xl">
            2-1 • 1-1 • 0-0
          </div>

          <p className="text-gray-300 leading-8 mt-6">
            Da questo unico pronostico FantaGol calcola automaticamente:
          </p>

          <ul className="mt-4 space-y-2 text-gray-300">
            <li>• Risultato Esatto</li>
            <li>• Segno (1-X-2)</li>
            <li>• Over / Under (2.5)</li>
            <li>• Goal / No Goal</li>
            <li>• Bonus e Malus</li>
          </ul>
        </section>

        <section className="mb-16">
          <h2 className="text-3xl font-bold mb-6">
            Sistema Punti
          </h2>

          <div className="space-y-4">

            <div className="p-4 border border-gray-800 rounded-xl">
              <strong>Exact</strong> → 11 punti
            </div>

            <div className="p-4 border border-gray-800 rounded-xl">
              <strong>Segno corretto</strong> → 3 punti
            </div>

            <div className="p-4 border border-gray-800 rounded-xl">
              <strong>Over / Under corretto</strong> → 1 punto
            </div>

            <div className="p-4 border border-gray-800 rounded-xl">
              <strong>Goal / No Goal corretto</strong> → 1 punto
            </div>

          </div>

          <p className="mt-6 text-gray-400">
            L'Exact è il cuore del gioco e rappresenta la massima
            espressione di precisione.
          </p>
        </section>

        <section className="mb-16">
          <h2 className="text-3xl font-bold mb-6">
            Bonus
          </h2>

          <div className="space-y-4">

            <div className="p-4 border border-green-900 rounded-xl">
              <strong>Gol Show (+1)</strong>

              <p className="text-gray-400 mt-2">
                Assegnato quando la somma gol pronosticata coincide
                con la somma gol reale e il totale gol della partita
                è pari o superiore a 4.
              </p>
            </div>

            <div className="p-4 border border-green-900 rounded-xl">
              <strong>Bonus Sorpresa (+2)</strong>

              <p className="text-gray-400 mt-2">
                Assegnato quando il giocatore indovina un esito
                considerato particolarmente improbabile dal mercato
                pre-partita.
                Il sistema determina automaticamente quali risultati
                rientrano nella categoria Sorpresa utilizzando una
                media di quote provenienti da più bookmaker.
              </p>
            </div>

            <div className="p-4 border border-green-900 rounded-xl">
              <strong>Grand Slam (+1)</strong>

              <p className="text-gray-400 mt-2">
                Bonus speciale ottenuto quando Exact, Gol Show e
                Bonus Sorpresa si verificano contemporaneamente.
                Rappresenta il massimo riconoscimento ottenibile
                in FantaGol.
              </p>
            </div>

          </div>
        </section>

        <section className="mb-16">
          <h2 className="text-3xl font-bold mb-6">
            Malus
          </h2>

          <div className="space-y-4">

            <div className="p-4 border border-red-900 rounded-xl">
              <strong>Segno Opposto (-1)</strong>

              <p className="text-gray-400 mt-2">
                Quando viene pronosticato 1 e termina 2 oppure
                viceversa.
              </p>
            </div>

            <div className="p-4 border border-red-900 rounded-xl">
              <strong>Cantonata (-2)</strong>

              <p className="text-gray-400 mt-2">
                Quando risultano errati contemporaneamente
                Segno, Over/Under e Goal/No Goal.
              </p>
            </div>

          </div>

          <p className="mt-6 text-gray-400">
            I punteggi negativi sono consentiti e possono influenzare
            le classifiche.
          </p>
        </section>

        <section className="mb-16">
          <h2 className="text-3xl font-bold mb-6">
            Modalità di Gioco
          </h2>

          <div className="space-y-6">

            <div className="p-6 border border-gray-800 rounded-2xl">
              <h3 className="text-2xl font-semibold mb-3">
                Fantacalcio
              </h3>

              <p className="text-gray-300 mb-4">
                I punti FantaGol vengono convertiti in gol tramite
                fasce prestabilite.
              </p>

              <div className="text-gray-400 space-y-1">
                <div>0-20 = 0 gol</div>
                <div>21-26 = 1 gol</div>
                <div>27-32 = 2 gol</div>
                <div>33-38 = 3 gol</div>
                <div>39-44 = 4 gol</div>
                <div>45-50 = 5 gol</div>
                <div>51-56 = 6 gol</div>
                <div>57-62 = 7 gol</div>
              </div>

              <p className="text-gray-400 mt-4">
                Dal primo gol in poi, ogni fascia copre 6 punti.
              </p>
            </div>

            <div className="p-6 border border-gray-800 rounded-2xl">
              <h3 className="text-2xl font-semibold mb-3">
                One To One
              </h3>

              <p className="text-gray-300">
                Ogni partita della giornata diventa una mini-sfida.
                Chi ottiene più punti FantaGol vince la mini-sfida.
                Vince la giornata chi conquista più mini-sfide.
              </p>
            </div>

            <div className="p-6 border border-gray-800 rounded-2xl">
              <h3 className="text-2xl font-semibold mb-3">
                Punti Puri
              </h3>

              <p className="text-gray-300">
                Conta esclusivamente la somma dei punti FantaGol
                ottenuti durante la stagione.
                Le giornate negative riducono il totale accumulato.
              </p>
            </div>

          </div>
        </section>

        <section>
          <h2 className="text-3xl font-bold mb-6">
            Un solo gioco. Tre campionati.
          </h2>

          <p className="text-gray-300 leading-8">
            Con un unico set di pronostici puoi partecipare
            contemporaneamente alle classifiche Fantacalcio,
            One To One e Punti Puri.
          </p>
        </section>

      </div>
    </main>
  );
}