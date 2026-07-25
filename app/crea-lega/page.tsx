"use client";

import { useState } from "react";
import Header from "../../components/Header";
import { supabase } from "../../lib/supabaseClient";

type CreatePrivateLeagueResult = {
  league_id: string;
  invite_code: string;
  visibility: "private";
};

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

function extractBackendError(message: string) {
  const knownErrors = [
    "AUTH_REQUIRED",
    "LEAGUE_NAME_REQUIRED",
    "DISPLAY_NAME_REQUIRED",
    "INVALID_LEAGUE_VISIBILITY",
    "NO_ACTIVE_COMPETITION_EDITION",
  ];

  return (
    knownErrors.find((knownError) => message.includes(knownError)) ?? message
  );
}

function getCreationErrorMessage(message: string) {
  switch (extractBackendError(message)) {
    case "AUTH_REQUIRED":
      return "La sessione non è valida. Accedi nuovamente e riprova.";

    case "LEAGUE_NAME_REQUIRED":
      return "Inserisci il nome della lega.";

    case "DISPLAY_NAME_REQUIRED":
      return "Inserisci il tuo nome nella lega.";

    case "INVALID_LEAGUE_VISIBILITY":
      return "Il tipo di lega richiesto non è valido.";

    case "NO_ACTIVE_COMPETITION_EDITION":
      return "Non è disponibile una competizione attiva per creare la lega.";

    default:
      return message || "Errore nella creazione della lega.";
  }
}

export default function CreaLegaPage() {
  const [leagueName, setLeagueName] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [createdLeague, setCreatedLeague] =
    useState<CreatePrivateLeagueResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");

  async function handleCreateLeague(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (loading) {
      return;
    }

    setLoading(true);
    setErrorMessage("");
    setCreatedLeague(null);

    const normalizedLeagueName = leagueName.trim();
    const normalizedDisplayName = displayName.trim();

    if (!normalizedLeagueName) {
      setErrorMessage("Inserisci il nome della lega.");
      setLoading(false);
      return;
    }

    if (!normalizedDisplayName) {
      setErrorMessage("Inserisci il tuo nome nella lega.");
      setLoading(false);
      return;
    }

    const { data, error } = await supabase.rpc("create_league_v2_rpc", {
      league_name: normalizedLeagueName,
      member_display_name: normalizedDisplayName,
      league_visibility: "private",
      expected_schedule_version: 1,
    });

    if (error) {
      setErrorMessage(getCreationErrorMessage(error.message));
      setLoading(false);
      return;
    }

    const result = data?.[0] as CreatePrivateLeagueResult | undefined;

    if (!result?.league_id || !result.invite_code) {
      setErrorMessage("La lega è stata creata senza una risposta valida.");
      setLoading(false);
      return;
    }

    window.localStorage.setItem(LAST_LEAGUE_STORAGE_KEY, result.league_id);

    setCreatedLeague({
      league_id: result.league_id,
      invite_code: result.invite_code,
      visibility: "private",
    });
    setLoading(false);
  }

  const inviteLink = createdLeague
    ? `${window.location.origin}/invito/${createdLeague.invite_code}`
    : "";

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-2xl rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#A6E824]">
            Nuova Lega
          </p>

          <h1 className="mb-3 text-3xl font-black">Crea la tua lega</h1>

          <p className="mb-8 text-gray-400">
            Scegli il tipo di lega che vuoi creare oppure consulta quelle già
            disponibili nel catalogo pubblico.
          </p>

          <section className="mb-8 grid gap-3 sm:grid-cols-2">
            <div className="rounded-2xl border border-[#A6E824] bg-[#A6E824]/10 p-5 text-left">
              <span className="block font-bold text-white">Privata</span>

              <span className="mt-2 block text-sm leading-6 text-gray-400">
                Partecipano soltanto gli utenti che ricevono il link di invito.
              </span>
            </div>

            <button
              type="button"
              onClick={() => window.location.assign("/leghe/pubbliche")}
              className="rounded-2xl border border-[#73CFE6] bg-[#73CFE6]/10 p-5 text-left transition hover:bg-[#73CFE6]/15"
            >
              <span className="block font-bold text-white">Pubblica</span>

              <span className="mt-2 block text-sm leading-6 text-gray-400">
                Consulta il catalogo, entra in una lega oppure creane una nuova.
              </span>
            </button>
          </section>

          <form onSubmit={handleCreateLeague} className="space-y-6">
            <div>
              <label
                htmlFor="league-name"
                className="mb-2 block text-sm font-semibold text-gray-300"
              >
                Nome lega
              </label>

              <input
                id="league-name"
                type="text"
                required
                maxLength={80}
                value={leagueName}
                onChange={(event) => setLeagueName(event.target.value)}
                placeholder="Es. Amici del Bar"
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
              />
            </div>

            <div>
              <label
                htmlFor="display-name"
                className="mb-2 block text-sm font-semibold text-gray-300"
              >
                Il tuo nome in questa lega
              </label>

              <input
                id="display-name"
                type="text"
                required
                maxLength={60}
                value={displayName}
                onChange={(event) => setDisplayName(event.target.value)}
                placeholder="Es. Cesare"
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
              />
            </div>

            {errorMessage && (
              <div
                role="alert"
                className="rounded-xl border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm text-red-200"
              >
                {errorMessage}
              </div>
            )}

            <button
              type="submit"
              disabled={loading}
              className="w-full rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {loading ? "Creazione in corso..." : "Crea Lega Privata"}
            </button>
          </form>

          {createdLeague && (
            <section className="mt-8 rounded-2xl border border-gray-700 bg-[#111111] p-5">
              <p className="text-sm font-semibold uppercase tracking-[0.18em] text-[#A6E824]">
                Lega creata
              </p>

              <h2 className="mt-2 text-xl font-bold">Lega privata pronta</h2>

              <p className="mt-2 text-sm leading-6 text-gray-400">
                Condividi il link di invito con le persone che vuoi aggiungere
                alla lega.
              </p>

              <div className="mt-5 break-all rounded-xl border border-gray-700 bg-black px-4 py-3 text-sm text-gray-300">
                {inviteLink}
              </div>

              <div className="mt-4 grid gap-3 sm:grid-cols-2">
                <button
                  type="button"
                  onClick={() => void navigator.clipboard.writeText(inviteLink)}
                  className="rounded-xl border border-[#A6E824]/50 px-5 py-3 font-semibold text-[#A6E824] transition hover:border-[#A6E824]"
                >
                  Copia Link
                </button>

                <button
                  type="button"
                  onClick={() =>
                    window.location.assign(`/leghe/${createdLeague.league_id}`)
                  }
                  className="rounded-xl bg-[#A6E824] px-5 py-3 font-semibold text-black transition hover:brightness-110"
                >
                  Entra nella Lega
                </button>
              </div>
            </section>
          )}
        </div>
      </section>
    </main>
  );
}
