import Header from "../../components/Header";

export default function DownloadPage() {
  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <div className="flex items-center justify-center py-32">
        <div className="text-center max-w-3xl px-6">

          <h1 className="text-6xl font-black mb-6">
            Download App
          </h1>

          <p className="text-xl text-gray-400 mb-10">
            Le app ufficiali FantaGol arriveranno presto.
          </p>

          <div className="flex flex-col md:flex-row gap-4 justify-center">

            <button className="px-8 py-4 border border-gray-700 rounded-xl">
              Android - Coming Soon
            </button>

            <button className="px-8 py-4 border border-gray-700 rounded-xl">
              iPhone - Coming Soon
            </button>

          </div>

        </div>
      </div>
    </main>
  );
}
