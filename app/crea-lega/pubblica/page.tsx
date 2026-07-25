"use client";

import { useEffect, useState } from "react";
import Header from "../../../components/Header";
import { supabase } from "../../../lib/supabaseClient";

type PublicLeagueSchedule = {
  starts_from_fantagol_round_id: string;
  starts_from_round_sequence: number;
  starts_from_round_name: string;
  first_useful_kickoff_at: string;
  automatic_join_close_at: string | null;
  inactivity_evaluation_round_id: string | null;
  inactivity_evaluation_at: string | null;
  schedule_version: number;
};

type CreatePublicLeagueResult = {
  league_id: string;
  invite_code: string;
  visibility: "public";
  starts_from_fantagol_round_id: string | null;
  first_useful_kickoff_at: string | null;
  automatic_join_close_at: string | null;
  inactivity_evaluation_round_id: string | null;
  inactivity_evaluation_at: string | null;
};

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

const dateTimeFormatter = new Intl.DateTimeFormat("it-IT", {
  dateStyle: "long",
  timeStyle: "short",
});

function formatDateTime(value: string | null) {
  if (!value) {
    return "Data non disponibile";
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return "Data non disponibile";
  }

  return dateTimeFormatter.format(date);
}

function extractBackendError(message: string) {
  const knownErrors = [
    "AUTH_REQUIRED",
    "LEAGUE_NAME_REQUIRED",
    "DISPLAY_NAME_REQUIRED",
    "INVALID_LEAGUE_VISIBILITY",
    "NO_ACTIVE_COMPETITION_EDITION",
    "PUBLIC_LEAGUE_NO_ELIGIBLE_START_ROUND",
    "PUBLIC_LEAGUE_SCHEDULE_CHANGED",
    "PUBLIC_LEAGUE_INVALID_MAX_PARTICIPANTS",
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

    case "PUBLIC_LEAGUE_NO_ELIGIBLE_START_ROUND":
      return "In questo momento non esiste una giornata utile per avviare una lega pubblica.";

    case "PUBLIC_LEAGUE_SCHEDULE_CHANGED":
      return "Il calendario della competizione è cambiato. L'anteprima è stata aggiornata: verifica i dati e riprova.";

    case "PUBLIC_LEAGUE_INVALID_MAX_PARTICIPANTS":
      return "La capacità della lega pubblica deve essere compresa tra 2 e 20 partecipanti.";

    default:
      return message || "Errore nella creazione della lega pubblica.";
  }
}

function getScheduleErrorMessage(message: string) {
  switch (extractBackendError(message)) {
    case "AUTH_REQUIRED":
      return "La sessione non è valida. Accedi nuovamente e riprova.";

    case "NO_ACTIVE_COMPETITION_EDITION":
      return "Non è disponibile una competizione attiva.";

    case "PUBLIC_LEAGUE_NO_ELIGIBLE_START_ROUND":
      return "Non esiste ancora una giornata utile per avviare una lega pubblica.";

    default:
      return "Non è stato possibile calcolare il calendario della lega pubblica.";
  }
}

export default function CreaLegaPubblicaPage() {
  const [leagueName, setLeagueName] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [maxParticipants, setMaxParticipants] = useState(8);
  const [publicSchedule, setPublicSchedule] =
    useState<PublicLeagueSchedule | null>(null);
  const [scheduleLoading, setScheduleLoading] = useState(true);
  const [scheduleError, setScheduleError] = useState("");
  const [scheduleRefreshKey, setScheduleRefreshKey] = useState(0);
  const [createdLeague, setCreatedLeague] =
    useState<CreatePublicLeagueResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    let active = true;

    async function loadPublicSchedule() {
      setScheduleLoading(true);
      setScheduleError("");
      setPublicSchedule(null);

      const { data, error } = await supabase.rpc(
        "resolve_public_league_schedule_rpc",
      );

      if (!active) {
        return;
      }

      if (error) {
        setScheduleError(getScheduleErrorMessage(error.message));
        setScheduleLoading(false);
        return;
      }

      const schedule = data?.[0] as PublicLeagueSchedule | undefined;

      if (
        !schedule?.starts_from_fantagol_round_id ||
        !schedule.starts_from_round_name ||
        !schedule.first_useful_kickoff_at ||
        !Number.isInteger(schedule.schedule_version)
      ) {
        setScheduleError(
          "Il backend non ha restituito un calendario pubblico valido.",
        );
        setScheduleLoading(false);
        return;
      }

      setPublicSchedule(schedule);
      setScheduleLoading(false);
    }

    void loadPublicSchedule();

    return () => {
      active = false;
    };
  }, [scheduleRefreshKey]);

  async function handleCreateLeague(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (loading) {
      return;
    }

    setLoading(true);
    setErrorMessage("");

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

    if (!publicSchedule) {
      setErrorMessage(
        "Attendi il caricamento del calendario prima di creare la lega.",
      );
      setLoading(false);
      return;
    }

    if (
      !Number.isInteger(maxParticipants) ||
      maxParticipants < 2 ||
      maxParticipants > 20
    ) {
      setErrorMessage(
        "La capacità della lega deve essere compresa tra 2 e 20 partecipanti.",
      );
      setLoading(false);
      return;
    }

    const { data, error } = await supabase.rpc("create_league_v2_rpc", {
      league_name: normalizedLeagueName,
      member_display_name: normalizedDisplayName,
      league_visibility: "public",
      expected_schedule_version: publicSchedule.schedule_version,
      public_max_participants: maxParticipants,
    });

    if (error) {
      const backendError = extractBackendError(error.message);

      setErrorMessage(getCreationErrorMessage(error.message));
      setLoading(false);

      if (backendError === "PUBLIC_LEAGUE_SCHEDULE_CHANGED") {
        setPublicSchedule(null);
        setScheduleRefreshKey((current) => current + 1);
      }

      return;
    }

    const result = data?.[0] as CreatePublicLeagueResult | undefined;

    if (!result?.league_id || !result.invite_code) {
      setErrorMessage(
        "La lega pubblica è stata creata senza una risposta valida.",
      );
      setLoading(false);
      return;
    }

    window.localStorage.setItem(LAST_LEAGUE_STORAGE_KEY, result.league_id);

    setCreatedLeague({
      ...result,
      visibility: "public",
    });
    setLoading(false);
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <Header />

      <section className="mx-auto flex min-h-[calc(100vh-56px)] max-w-6xl items-center justify-center px-6 py-16">
        <div className="w-full max-w-2xl rounded-3xl border border-gray-700 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-8 shadow-2xl shadow-black/70">
          <button
            type="button"
            onClick={() => window.location.assign("/leghe/pubbliche")}
            className="mb-7 text-sm font-semibold text-gray-400 transition hover:text-white"
          >
            Torna al catalogo pubblico
          </button>

          <p className="mb-3 text-sm font-semibold uppercase tracking-[0.25em] text-[#73CFE6]">
            Nuova Lega Pubblica
          </p>

          <h1 className="mb-3 text-3xl font-black">Crea una lega pubblica</h1>

          <p className="mb-8 leading-7 text-gray-400">
            La lega sarà visibile nel catalogo pubblico. Gli utenti potranno
            entrare finché l'amministratore manterrà aperte le iscrizioni.
          </p>

          <section className="mb-6 rounded-2xl border border-[#73CFE6]/30 bg-[#73CFE6]/5 p-5">
            <p className="font-semibold text-[#73CFE6]">
              Iscrizioni controllate dall'amministratore
            </p>

            <p className="mt-2 text-sm leading-6 text-gray-300">
              Non è prevista una chiusura automatica. Potrai chiudere o riaprire
              le iscrizioni dalla gestione della lega.
            </p>
          </section>

          <section className="mb-8 rounded-2xl border border-gray-700 bg-[#111111] p-5">
            <div className="flex items-start justify-between gap-4">
              <div>
                <p className="text-sm font-semibold uppercase tracking-[0.16em] text-gray-400">
                  Calendario della lega pubblica
                </p>

                <p className="mt-2 text-sm leading-6 text-gray-400">
                  La giornata iniziale viene calcolata dal calendario ufficiale
                  attualmente disponibile.
                </p>
              </div>

              {scheduleLoading && (
                <span className="shrink-0 text-sm text-[#73CFE6]">
                  Calcolo...
                </span>
              )}
            </div>

            {scheduleError && (
              <div className="mt-4 rounded-xl border border-red-500/40 bg-red-500/10 p-4">
                <p className="text-sm text-red-200">{scheduleError}</p>

                <button
                  type="button"
                  onClick={() =>
                    setScheduleRefreshKey((current) => current + 1)
                  }
                  className="mt-3 text-sm font-semibold text-[#73CFE6]"
                >
                  Riprova
                </button>
              </div>
            )}

            {publicSchedule && (
              <dl className="mt-5 grid gap-4 sm:grid-cols-2">
                <div className="rounded-xl border border-gray-800 bg-black p-4">
                  <dt className="text-xs font-semibold uppercase tracking-[0.14em] text-gray-500">
                    Giornata iniziale
                  </dt>

                  <dd className="mt-2 font-semibold text-white">
                    {publicSchedule.starts_from_round_name}
                  </dd>
                </div>

                <div className="rounded-xl border border-gray-800 bg-black p-4">
                  <dt className="text-xs font-semibold uppercase tracking-[0.14em] text-gray-500">
                    Primo calcio d&apos;inizio
                  </dt>

                  <dd className="mt-2 font-semibold text-white">
                    {formatDateTime(publicSchedule.first_useful_kickoff_at)}
                  </dd>
                </div>
              </dl>
            )}
          </section>

          <form onSubmit={handleCreateLeague} className="space-y-6">
            <div>
              <label
                htmlFor="public-league-name"
                className="mb-2 block text-sm font-semibold text-gray-300"
              >
                Nome lega
              </label>

              <input
                id="public-league-name"
                type="text"
                required
                maxLength={80}
                value={leagueName}
                onChange={(event) => setLeagueName(event.target.value)}
                placeholder="Es. Campioni d'Italia"
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#73CFE6]"
              />
            </div>

            <div>
              <label
                htmlFor="public-display-name"
                className="mb-2 block text-sm font-semibold text-gray-300"
              >
                Il tuo nome in questa lega
              </label>

              <input
                id="public-display-name"
                type="text"
                required
                maxLength={60}
                value={displayName}
                onChange={(event) => setDisplayName(event.target.value)}
                placeholder="Es. Cesare"
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#73CFE6]"
              />
            </div>

            <div>
              <label
                htmlFor="public-max-participants"
                className="mb-2 block text-sm font-semibold text-gray-300"
              >
                Numero massimo di partecipanti
              </label>

              <select
                id="public-max-participants"
                value={maxParticipants}
                onChange={(event) =>
                  setMaxParticipants(Number(event.target.value))
                }
                className="w-full rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition focus:border-[#73CFE6]"
              >
                {Array.from({ length: 19 }, (_, index) => index + 2).map(
                  (capacity) => (
                    <option key={capacity} value={capacity}>
                      {capacity} partecipanti
                    </option>
                  ),
                )}
              </select>

              <p className="mt-2 text-sm leading-6 text-gray-500">
                L&apos;amministratore occupa già uno dei posti disponibili.
                Quando viene raggiunta la capacità massima, la lega risulta
                completa e non accetta nuovi ingressi.
              </p>
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
              disabled={loading || scheduleLoading || !publicSchedule}
              className="w-full rounded-xl bg-[#73CFE6] px-5 py-3 font-semibold text-black shadow-lg shadow-[#73CFE6]/20 transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
            >
              {loading
                ? "Creazione in corso..."
                : scheduleLoading
                  ? "Calcolo calendario..."
                  : "Crea Lega Pubblica"}
            </button>
          </form>
        </div>
      </section>

      {createdLeague && (
        <div
          role="dialog"
          aria-modal="true"
          aria-labelledby="public-league-created-title"
          className="fixed inset-0 z-[100] flex items-center justify-center bg-black/80 px-6 py-10 backdrop-blur-sm"
        >
          <section className="w-full max-w-lg rounded-3xl border border-[#73CFE6]/40 bg-gradient-to-b from-[#202620] to-[#0b0b0b] p-7 shadow-2xl shadow-black">
            <div className="flex h-14 w-14 items-center justify-center rounded-full bg-[#73CFE6] text-lg font-black text-black">
              OK
            </div>

            <p className="mt-6 text-sm font-semibold uppercase tracking-[0.2em] text-[#73CFE6]">
              Creazione completata
            </p>

            <h2
              id="public-league-created-title"
              className="mt-2 text-2xl font-black text-white"
            >
              La tua lega è stata aggiunta
            </h2>

            <p className="mt-4 leading-7 text-gray-300">
              La lega pubblica{" "}
              <span className="font-bold text-white">
                &ldquo;{leagueName.trim()}&rdquo;
              </span>{" "}
              è ora disponibile nel catalogo.
            </p>

            <p className="mt-3 text-sm leading-6 text-gray-400">
              Apri il catalogo per verificare come viene mostrata agli altri
              utenti oppure entra direttamente nella lega.
            </p>

            <div className="mt-7 space-y-3">
              <button
                type="button"
                autoFocus
                onClick={() => window.location.assign("/leghe/pubbliche")}
                className="w-full rounded-xl bg-[#73CFE6] px-5 py-3 font-semibold text-black transition hover:brightness-110"
              >
                Vai al catalogo pubblico
              </button>

              <button
                type="button"
                onClick={() =>
                  window.location.assign(`/leghe/${createdLeague.league_id}`)
                }
                className="w-full rounded-xl border border-gray-600 px-5 py-3 font-semibold text-white transition hover:border-gray-400"
              >
                Apri la lega
              </button>
            </div>
          </section>
        </div>
      )}
    </main>
  );
}
