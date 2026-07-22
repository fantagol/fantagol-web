import Header from "../../components/Header";

export default function RegolamentoPage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <div className="mx-auto max-w-4xl px-6 py-20">
        <h1 className="mb-6 text-5xl font-black">
          Regolamento Ufficiale FantaGol
        </h1>

        <p className="mb-6 text-xl text-gray-400">
          Un solo pronostico. Tre modalità di gioco. Infinite sfide.
        </p>

        <p className="mb-16 text-gray-400">
          Per garantire il miglior equilibrio competitivo è consigliata la partecipazione con un numero pari di giocatori.
          Le leghe con un numero dispari di partecipanti sono comunque pienamente supportate.
        </p>

        <section className="mb-16">
          <h2 className="mb-6 text-3xl font-bold">Come si gioca</h2>

          <p className="leading-8 text-gray-300">
            Per ogni partita devi inserire un solo pronostico: il risultato esatto.
          </p>

          <div className="mt-4 rounded-xl border border-gray-800 p-4">
            2-1 • 1-1 • 0-0
          </div>

          <p className="mt-6 leading-8 text-gray-300">
            Da questo unico pronostico FantaGol calcola automaticamente:
          </p>

          <ul className="mt-4 space-y-2 text-gray-300">
            <li>• Risultato esatto</li>
            <li>• Segno 1-X-2</li>
            <li>• Over / Under 2.5</li>
            <li>• Goal / No Goal</li>
            <li>• Bonus e malus</li>
          </ul>
        </section>

        <section className="mb-16">
          <h2 className="mb-6 text-3xl font-bold">Sistema Punti</h2>

          <div className="space-y-4">
            <div className="rounded-xl border border-gray-800 p-4">
              <strong>Risultato esatto</strong> → 6 punti
            </div>

            <div className="rounded-xl border border-gray-800 p-4">
              <strong>Segno corretto</strong> → 3 punti
            </div>

            <div className="rounded-xl border border-gray-800 p-4">
              <strong>Over / Under 2.5 corretto</strong> → 1 punto
            </div>

            <div className="rounded-xl border border-gray-800 p-4">
              <strong>Goal / No Goal corretto</strong> → 1 punto
            </div>
          </div>

          <p className="mt-6 text-gray-400">
            Un pronostico esatto assegna complessivamente 11 punti: 6 per
            l&apos;Exact, 3 per il Segno, 1 per Over / Under e 1 per Goal / No Goal.
            Senza Exact, il massimo ottenibile attraverso i quattro parametri base è
            di 5 punti.
          </p>
        </section>

        <section className="mb-16">
          <h2 className="mb-6 text-3xl font-bold">Bonus</h2>

          <div className="space-y-4">
            <div className="rounded-xl border border-green-900 p-4">
              <strong>Gol Show (+1)</strong>

              <p className="mt-2 text-gray-400">
                Assegnato quando la somma dei gol pronosticati coincide con la
                somma dei gol reali e il totale dei gol della partita è pari o
                superiore a 4.
              </p>
            </div>

            <div className="rounded-xl border border-green-900 p-4">
              <strong>Bonus Sorpresa (+2)</strong>

              <p className="mt-2 text-gray-400">
                Assegnato quando il giocatore indovina un esito considerato
                particolarmente improbabile dal mercato pre-partita. Il sistema
                determina automaticamente gli esiti Sorpresa utilizzando una
                media delle quote provenienti da più bookmaker.
              </p>
            </div>

            <div className="rounded-xl border border-green-900 p-4">
              <strong>Grande Slam (+1)</strong>

              <p className="mt-2 text-gray-400">
                Assegnato quando Exact, Gol Show e Bonus Sorpresa si verificano
                contemporaneamente nella stessa partita.
              </p>
            </div>
          </div>

          <p className="mt-6 text-gray-400">
            Il punteggio massimo ottenibile su una singola partita è di 14 punti.
          </p>
        </section>

        <section className="mb-16">
          <h2 className="mb-6 text-3xl font-bold">Malus</h2>

          <div className="space-y-4">
            <div className="rounded-xl border border-red-900 p-4">
              <strong>Segno Opposto (-1)</strong>

              <p className="mt-2 text-gray-400">
                Si applica quando viene pronosticata la vittoria della squadra di
                casa e vince la squadra ospite, oppure viceversa.
              </p>
            </div>

            <div className="rounded-xl border border-red-900 p-4">
              <strong>Cantonata (-2)</strong>

              <p className="mt-2 text-gray-400">
                Si applica quando risultano errati contemporaneamente Segno,
                Over / Under e Goal / No Goal. Non è cumulabile con il malus
                Segno Opposto.
              </p>
            </div>
          </div>

          <p className="mt-6 text-gray-400">
            I punteggi negativi sono consentiti e incidono sul punteggio della
            giornata e sulle classifiche cumulative.
          </p>
        </section>

        <section className="mb-16">
          <h2 className="mb-6 text-3xl font-bold">Modalità di Gioco</h2>

          <div className="space-y-6">
            <div className="rounded-2xl border border-gray-800 p-6">
              <h3 className="mb-3 text-2xl font-semibold">Fantacalcio</h3>

              <p className="mb-4 text-gray-300">
                Ogni giocatore utilizza gli stessi 10 pronostici della giornata,
                ma deve distribuirli obbligatoriamente in due reparti da 5
                partite ciascuno: Attacco e Difesa.
              </p>

              <div className="space-y-4">
                <div className="rounded-xl border border-red-900 p-4">
                  <strong>Attacco — 5 partite</strong>

                  <p className="mt-2 text-gray-400">
                    Nelle partite schierate in Attacco l&apos;Exact e il Bonus
                    Sorpresa valgono il doppio. Anche i malus Segno Opposto e
                    Cantonata vengono raddoppiati. L&apos;Attacco offre quindi un
                    potenziale maggiore, ma espone a un rischio più elevato.
                  </p>
                </div>

                <div className="rounded-xl border border-green-900 p-4">
                  <strong>Difesa — 5 partite</strong>

                  <p className="mt-2 text-gray-400">
                    Nelle partite schierate in Difesa i bonus mantengono il loro
                    valore normale, mentre i malus Segno Opposto e Cantonata
                    vengono dimezzati. La Difesa riduce il rischio senza
                    aumentare i bonus.
                  </p>
                </div>
              </div>

              <p className="mt-6 text-gray-400">
                La composizione dei due reparti può essere modificata fino al
                blocco dei pronostici. Al termine della giornata, il punteggio
                complessivo viene convertito in gol utilizzando una base di 23
                punti e fasce da 10 punti ciascuna, secondo il regolamento
                ufficiale della modalità Fantacalcio.
              </p>

              <div className="mt-6 rounded-xl border border-blue-900 p-4">
                <h4 className="mb-3 font-semibold">Conversione Fantacalcio</h4>

                <div className="space-y-2 text-gray-300">
                  <div>&lt; 23 punti → 0 gol</div>
                  <div>23–32 punti → 1 gol</div>
                  <div>33–42 punti → 2 gol</div>
                  <div>43–52 punti → 3 gol</div>
                  <div>53–62 punti → 4 gol</div>
                </div>

                <p className="mt-4 text-sm text-gray-400">
                  La progressione continua con fasce di 10 punti per ogni gol successivo.
                </p>
              </div>
            </div>

            <div className="rounded-2xl border border-gray-800 p-6">
              <h3 className="mb-3 text-2xl font-semibold">One To One</h3>

              <p className="text-gray-300">
                Ogni giocatore affronta un avversario di giornata attraverso
                mini-sfide costruite strategicamente sui 10 pronostici.
              </p>

              <p className="mt-4 text-gray-400">
                Gli accoppiamenti non sono fissi partita contro la stessa
                partita. Ogni giocatore decide contro quale pronostico
                dell&apos;avversario mandare in sfida ciascuno dei propri
                pronostici, utilizzando ogni pronostico una sola volta.
              </p>

              <p className="mt-4 text-gray-400">
                Si generano così due matrici indipendenti da 10 mini-sfide:
                una costruita dal primo giocatore e una costruita dal secondo.
                In ogni mini-sfida prevale il pronostico che ottiene più punti
                FantaGol; in caso di parità la mini-sfida termina in pareggio.
                La somma dei risultati delle due matrici determina l&apos;esito
                finale dell&apos;incontro One To One.
              </p>

              <p className="mt-4 text-gray-400">
                Le matrici possono essere modificate fino al blocco dei
                pronostici e restano nascoste all&apos;avversario fino all&apos;inizio
                della giornata.
              </p>
            </div>

            <div className="rounded-2xl border border-gray-800 p-6">
              <h3 className="mb-3 text-2xl font-semibold">Punti Puri</h3>

              <p className="text-gray-300">
                Conta esclusivamente la somma dei punti FantaGol ottenuti durante
                la stagione. Le giornate negative riducono il totale accumulato.
              </p>
            </div>
          </div>
        </section>

        <section className="mb-16">
          <h2 className="mb-6 text-3xl font-bold">Strategia</h2>

          <p className="leading-8 text-gray-300">
            FantaGol non premia soltanto la capacità di prevedere i risultati,
            ma anche la capacità di organizzare e utilizzare strategicamente i
            propri pronostici.
          </p>

          <ul className="mt-6 space-y-3 text-gray-300">
            <li>• scegliere quali partite schierare in Attacco;</li>
            <li>• scegliere quali partite proteggere in Difesa;</li>
            <li>
              • decidere gli accoppiamenti delle mini-sfide nella modalità One To One.
            </li>
          </ul>

          <p className="mt-6 text-gray-400">
            Le scelte strategiche non modificano il pronostico inserito, ma
            possono incidere in modo determinante sul risultato finale delle
            modalità Fantacalcio e One To One.
          </p>
        </section>

        <section>
          <h2 className="mb-6 text-3xl font-bold">
            Un solo gioco. Tre campionati.
          </h2>

          <p className="leading-8 text-gray-300">
            Con un unico set di pronostici puoi partecipare contemporaneamente
            alle classifiche Fantacalcio, One To One e Punti Puri.
          </p>
        </section>
      </div>
    </main>
  );
}
