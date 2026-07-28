"use client";

import { useEffect, useState } from "react";
import FantaGolLogo from "../../../components/FantaGolLogo";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
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

type DrawerLeague = {
  id: string;
  name: string;
  invite_code: string;
  display_name: string;
  role: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  league_name?: string | null;
  invite_code?: string | null;
  display_name?: string | null;
  role?: string | null;
  status?: string | null;
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


function extractInviteCode(value: string) {
  const normalizedValue = value.trim();

  if (!normalizedValue) {
    return "";
  }

  try {
    const inviteUrl = new URL(normalizedValue);
    const pathParts = inviteUrl.pathname.split("/").filter(Boolean);
    const inviteIndex = pathParts.findIndex((part) => part === "invito");

    if (inviteIndex >= 0 && pathParts[inviteIndex + 1]) {
      return decodeURIComponent(pathParts[inviteIndex + 1]).trim();
    }
  } catch {
    // Il valore non è un URL completo: viene interpretato come codice.
  }

  const withoutQueryOrHash = normalizedValue.split(/[?#]/, 1)[0];
  const pathParts = withoutQueryOrHash.split("/").filter(Boolean);

  if (pathParts.length >= 2 && pathParts.at(-2) === "invito") {
    return decodeURIComponent(pathParts.at(-1) || "").trim();
  }

  return decodeURIComponent(pathParts.at(-1) || withoutQueryOrHash).trim();
}

export default function CreaLegaPubblicaPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [navigationResolved, setNavigationResolved] = useState(false);
  const [league, setLeague] = useState<DrawerLeague | null>(null);
  const [leagueName, setLeagueName] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [maxParticipants, setMaxParticipants] = useState(8);
  const [publicSchedule, setPublicSchedule] =
    useState<PublicLeagueSchedule | null>(null);
  const [scheduleLoading, setScheduleLoading] = useState(true);
  const [scheduleError, setScheduleError] = useState("");
  const [scheduleRefreshKey, setScheduleRefreshKey] = useState(0);
  const [loading, setLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");
  const [inviteValue, setInviteValue] = useState("");
  const [inviteErrorMessage, setInviteErrorMessage] = useState("");

  useEffect(() => {
    let active = true;

    async function loadAuthenticatedNavigation() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!active) return;

      if (!session?.user) {
        window.location.replace("/login");
        return;
      }

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");

      if (!active) return;

      if (!error) {
        const rows = ((data || []) as MyLeagueRpcRow[]).filter(
          (row) => row.status === "active" || !row.status,
        );

        const storedLeagueId = window.localStorage.getItem(
          LAST_LEAGUE_STORAGE_KEY,
        );

        const current =
          rows.find((row) => row.league_id === storedLeagueId) || rows[0];

        if (current) {
          window.localStorage.setItem(
            LAST_LEAGUE_STORAGE_KEY,
            current.league_id,
          );

          setLeague({
            id: current.league_id,
            name: current.league_name || "Lega FantaGol",
            invite_code: current.invite_code || "",
            display_name: current.display_name || "Giocatore",
            role: current.role || "member",
          });
        }
      }

      setNavigationResolved(true);
    }

    void loadAuthenticatedNavigation();

    return () => {
      active = false;
    };
  }, []);

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
    window.location.replace(`/leghe/${result.league_id}`);
  }

  function handleOpenInvite(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setInviteErrorMessage("");

    const inviteCode = extractInviteCode(inviteValue);

    if (!inviteCode) {
      setInviteErrorMessage(
        "Incolla un link di invito oppure inserisci il codice.",
      );
      return;
    }

    window.location.assign(`/invito/${encodeURIComponent(inviteCode)}`);
  }

  const activeLeague = league || {
    id: "",
    name: "FantaGol",
    invite_code: "",
    display_name: "Giocatore",
    role: "member",
  };

  return (
    <main className="min-h-screen bg-black text-white">
      {navigationResolved && (
        <>
          <HamburgerDrawer
            open={menuOpen}
            leagueName={activeLeague.name}
            displayName={activeLeague.display_name}
            inviteCode={activeLeague.invite_code}
            role={activeLeague.role}
            onClose={() => setMenuOpen(false)}
          />

          <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
            <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
              <a
                href={activeLeague.id ? `/leghe/${activeLeague.id}` : "/leghe"}
                className="relative z-10 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6"
              >
                <FantaGolLogo />
              </a>

              <button
                type="button"
                onClick={() => setMenuOpen(true)}
                aria-label="Apri menu lega"
                className="rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#73CFE6]"
              >
                ☰
              </button>
            </div>
          </header>
        </>
      )}

      <section className="mx-auto flex min-h-screen max-w-6xl items-center justify-center px-6 pb-16 pt-24">
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
            entrare finché l&apos;amministratore manterrà aperte le iscrizioni.
          </p>

          <section className="mb-6 rounded-2xl border border-[#73CFE6]/30 bg-[#73CFE6]/5 p-5">
            <p className="font-semibold text-[#73CFE6]">
              Iscrizioni controllate dall&apos;amministratore
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

          <section className="mt-8 border-t border-gray-700 pt-8">
            <p className="text-sm font-semibold uppercase tracking-[0.18em] text-[#73CFE6]">
              Hai ricevuto un invito?
            </p>

            <h2 className="mt-2 text-xl font-bold">Entra in un’altra lega</h2>

            <p className="mt-2 text-sm leading-6 text-gray-400">
              Incolla il link di invito completo oppure inserisci direttamente
              il codice ricevuto.
            </p>

            <form onSubmit={handleOpenInvite} className="mt-5 space-y-3">
              <label htmlFor="invite-value" className="sr-only">
                Link o codice di invito
              </label>

              <div className="flex flex-col gap-3 sm:flex-row">
                <input
                  id="invite-value"
                  type="text"
                  value={inviteValue}
                  onChange={(event) => {
                    setInviteValue(event.target.value);
                    if (inviteErrorMessage) setInviteErrorMessage("");
                  }}
                  placeholder="Incolla il link o il codice di invito"
                  autoComplete="off"
                  className="min-w-0 flex-1 rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#73CFE6]"
                />

                <button
                  type="submit"
                  className="shrink-0 rounded-xl border border-[#73CFE6]/60 bg-[#73CFE6]/10 px-5 py-3 font-semibold text-[#73CFE6] transition hover:border-[#73CFE6] hover:bg-[#73CFE6]/15"
                >
                  Continua
                </button>
              </div>

              {inviteErrorMessage && (
                <div
                  role="alert"
                  className="rounded-xl border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm text-red-200"
                >
                  {inviteErrorMessage}
                </div>
              )}
            </form>
          </section>
        </div>
      </section>
    </main>
  );
}
