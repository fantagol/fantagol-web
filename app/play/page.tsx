import Header from "../../components/Header";

export default function PlayPage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <div className="flex items-center justify-center py-32">
        <div className="text-center max-w-3xl px-6">

          <h1 className="text-6xl font-black mb-6">
            Play Online
          </h1>

          <p className="text-xl text-gray-400 mb-8">
            La versione web di FantaGol è in costruzione.
          </p>

          <p className="text-lg text-gray-500">
            Qui nasceranno leghe, pronostici, classifiche e sfide live.
          </p>

        </div>
      </div>
    </main>
  );
}
