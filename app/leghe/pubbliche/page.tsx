"use client";

import { useEffect, useState } from "react";
import HamburgerDrawer from "../../../components/app/HamburgerDrawer";
import { supabase } from "../../../lib/supabaseClient";

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";
const PENDING_AUTH_DESTINATION_KEY = "fantagol.pendingAuthDestination.v1";

type PublicLeagueRow = {
  league_id: string;
  league_name: string;
  edition_id: string;
  edition_label: string;
  admin_display_name: string;
  active_member_count: number;
  max_participants: number;
  available_slots: number;
  public_registrations_open: boolean;
  competition_started: boolean;
  roster_status: string;
  join_status: string;
  visibility: string;
  starts_from_fantagol_round_id: string | null;
  starts_from_round_name: string | null;
  starts_from_round_sequence: number | null;
  first_useful_kickoff_at: string | null;
  automatic_join_close_at: string | null;
  lifecycle_status: string;
  league_status: string;
  created_at: string;
  viewer_membership_status: string | null;
  viewer_is_member: boolean;
  viewer_can_join: boolean;
};

type DrawerLeagueContext = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type JoinPublicLeagueResult = {
  joined_league_id: string;
  membership_id: string;
  join_result: string;
};

const dateTimeFormatter = new Intl.DateTimeFormat("it-IT", {
  dateStyle: "long",
  timeStyle: "short",
});

function formatDateTime(value: string | null) {
  if (!value) {
    return null;
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return null;
  }

  return dateTimeFormatter.format(date);
}

async function resolveDrawerLeagueContext(): Promise<DrawerLeagueContext> {
  const { data, error } = await supabase.rpc("get_my_leagues_rpc");

  if (error || !data?.length) {
    return {
      leagueName: "Le tue leghe",
      displayName: "Club FantaGol",
      inviteCode: "",
      role: "member",
    };
  }

  const storedLeagueId = window.localStorage.getItem(LAST_LEAGUE_STORAGE_KEY);
  const selected =
    data.find(
      (row: { league_id?: string | null }) =>
        row.league_id === storedLeagueId,
    ) ?? data[0];

  return {
    leagueName: selected.league_name || "Lega FantaGol",
    displayName: selected.display_name || "Club FantaGol",
    inviteCode: selected.invite_code || "",
    role: selected.role || "member",
  };
}

function extractBackendError(message: string) {
  const knownErrors = [
    "AUTH_REQUIRED",
    "PUBLIC_LEAGUE_INVALID_PAGE_SIZE",
    "PUBLIC_LEAGUE_INVALID_ROSTER_FILTER",
    "PUBLIC_LEAGUE_INVALID_CURSOR",
    "PUBLIC_LEAGUE_NOT_FOUND",
    "DISPLAY_NAME_REQUIRED",
    "PUBLIC_LEAGUE_NOT_PUBLIC",
    "PUBLIC_LEAGUE_NOT_JOINABLE",
    "PUBLIC_LEAGUE_ROSTER_LOCKED",
    "PUBLIC_LEAGUE_REGISTRATIONS_CLOSED",
    "PUBLIC_LEAGUE_COMPETITION_STARTED",
    "PUBLIC_LEAGUE_FULL",
    "LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT",
  ];

  return (
    knownErrors.find((knownError) => message.includes(knownError)) ?? message
  );
}

function getCatalogErrorMessage(message: string) {
  switch (extractBackendError(message)) {
    case "AUTH_REQUIRED":
      return "La sessione non è valida. Accedi nuovamente e riprova.";

    case "PUBLIC_LEAGUE_INVALID_PAGE_SIZE":
    case "PUBLIC_LEAGUE_INVALID_ROSTER_FILTER":
    case "PUBLIC_LEAGUE_INVALID_CURSOR":
      return "Il catalogo ha ricevuto parametri non validi.";

    default:
      return message || "Non è stato possibile caricare le leghe pubbliche.";
  }
}

function getJoinErrorMessage(message: string) {
  switch (extractBackendError(message)) {
    case "AUTH_REQUIRED":
      return "La sessione non è valida. Accedi nuovamente e riprova.";

    case "DISPLAY_NAME_REQUIRED":
      return "Inserisci il nome che vuoi usare nella lega.";

    case "PUBLIC_LEAGUE_NOT_FOUND":
      return "La lega pubblica non è più disponibile.";

    case "PUBLIC_LEAGUE_NOT_PUBLIC":
      return "Questa lega non è più pubblica.";

    case "PUBLIC_LEAGUE_NOT_JOINABLE":
      return "In questo momento non è possibile entrare nella lega.";

    case "PUBLIC_LEAGUE_ROSTER_LOCKED":
    case "PUBLIC_LEAGUE_REGISTRATIONS_CLOSED":
      return "L'amministratore ha chiuso le iscrizioni alla lega.";

    case "PUBLIC_LEAGUE_COMPETITION_STARTED":
      return "Il campionato di questa lega è già iniziato.";

    case "PUBLIC_LEAGUE_FULL":
      return "La lega ha raggiunto il numero massimo di partecipanti.";

    case "LEAGUE_MEMBER_REMOVED_REQUIRES_REINSTATEMENT":
      return "La tua precedente partecipazione deve essere ripristinata dall'amministratore.";

    default:
      return message || "Non è stato possibile entrare nella lega.";
  }
}

export default function PublicLeaguesPage() {
  const [leagues, setLeagues] = useState<PublicLeagueRow[]>([]);
  const [menuOpen, setMenuOpen] = useState(false);
  const [drawerLeague, setDrawerLeague] = useState<DrawerLeagueContext>({
    leagueName: "Le tue leghe",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });
  const [loading, setLoading] = useState(true);
  const [catalogError, setCatalogError] = useState("");
  const [refreshKey, setRefreshKey] = useState(0);
  const [joiningLeagueId, setJoiningLeagueId] = useState<string | null>(null);
  const [selectedLeagueId, setSelectedLeagueId] = useState<string | null>(null);
  const [displayName, setDisplayName] = useState("");
  const [joinError, setJoinError] = useState("");

  useEffect(() => {
    let active = true;

    void resolveDrawerLeagueContext().then((context) => {
      if (active) {
        setDrawerLeague(context);
      }
    });

    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    let active = true;

    async function loadCatalog() {
      setLoading(true);
      setCatalogError("");

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!active) {
        return;
      }

      if (!session?.user) {
        const destination = "/leghe/pubbliche";

        window.localStorage.setItem(PENDING_AUTH_DESTINATION_KEY, destination);

        window.location.replace(
          `/login?returnTo=${encodeURIComponent(destination)}`,
        );
        return;
      }

      const { data, error } = await supabase.rpc("get_public_leagues_rpc", {
        page_size: 30,
        cursor_created_at: null,
        cursor_league_id: null,
        roster_filter: "all",
      });

      if (!active) {
        return;
      }

      if (error) {
        setCatalogError(getCatalogErrorMessage(error.message));
        setLoading(false);
        return;
      }

      setLeagues((data ?? []) as PublicLeagueRow[]);
      setLoading(false);
    }

    void loadCatalog();

    return () => {
      active = false;
    };
  }, [refreshKey]);

  function openLeague(leagueId: string) {
    window.localStorage.setItem(LAST_LEAGUE_STORAGE_KEY, leagueId);

    window.location.assign(`/leghe/${leagueId}`);
  }

  function startJoin(leagueId: string) {
    setSelectedLeagueId(leagueId);
    setDisplayName("");
    setJoinError("");
  }

  function cancelJoin() {
    if (joiningLeagueId) {
      return;
    }

    setSelectedLeagueId(null);
    setDisplayName("");
    setJoinError("");
  }

  async function joinLeague(leagueId: string) {
    if (joiningLeagueId) {
      return;
    }

    const normalizedDisplayName = displayName.trim();

    if (!normalizedDisplayName) {
      setJoinError("Inserisci il nome che vuoi usare nella lega.");
      return;
    }

    setJoiningLeagueId(leagueId);
    setJoinError("");

    const { data, error } = await supabase.rpc("join_public_league_rpc", {
      target_league_id: leagueId,
      member_display_name: normalizedDisplayName,
    });

    if (error) {
      setJoinError(getJoinErrorMessage(error.message));
      setJoiningLeagueId(null);

      if (
        extractBackendError(error.message) === "PUBLIC_LEAGUE_ROSTER_LOCKED" ||
        extractBackendError(error.message) ===
          "PUBLIC_LEAGUE_REGISTRATIONS_CLOSED" ||
        extractBackendError(error.message) ===
          "PUBLIC_LEAGUE_COMPETITION_STARTED" ||
        extractBackendError(error.message) === "PUBLIC_LEAGUE_FULL" ||
        extractBackendError(error.message) === "PUBLIC_LEAGUE_NOT_JOINABLE" ||
        extractBackendError(error.message) === "PUBLIC_LEAGUE_NOT_FOUND"
      ) {
        setRefreshKey((current) => current + 1);
      }

      return;
    }

    const result = data?.[0] as JoinPublicLeagueResult | undefined;

    if (!result?.joined_league_id || !result.membership_id) {
      setJoinError(
        "La partecipazione è stata registrata senza una risposta valida.",
      );
      setJoiningLeagueId(null);
      return;
    }

    window.localStorage.setItem(
      LAST_LEAGUE_STORAGE_KEY,
      result.joined_league_id,
    );

    window.location.assign(`/leghe/${result.joined_league_id}`);
  }

  return (
    <main className="min-h-screen bg-black text-white">
      <HamburgerDrawer
        open={menuOpen}
        leagueName={drawerLeague.leagueName}
        displayName={drawerLeague.displayName}
        inviteCode={drawerLeague.inviteCode}
        role={drawerLeague.role}
        onClose={() => setMenuOpen(false)}
      />


      <header className="sticky top-0 z-40 border-b border-white/10 bg-black/90 backdrop-blur">
        <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu FantaGol"
            className="flex h-11 w-11 items-center justify-center rounded-xl border border-white/10 bg-[#111417] transition hover:border-[#A6E824]/60"
          >
            <span className="space-y-1.5">
              <span className="block h-0.5 w-5 rounded-full bg-[#A6E824]" />
              <span className="block h-0.5 w-5 rounded-full bg-[#A6E824]" />
              <span className="block h-0.5 w-5 rounded-full bg-[#A6E824]" />
            </span>
          </button>

          <button
            type="button"
            onClick={() => window.location.assign("/leghe")}
            className="text-lg font-black tracking-tight text-white transition hover:text-[#A6E824]"
          >
            FantaGol
          </button>

          <div className="h-11 w-11" aria-hidden="true" />
        </div>
      </header>

      <section className="mx-auto max-w-6xl px-6 py-12 sm:py-16">
        <div className="mx-auto max-w-3xl text-center">
          <p className="text-sm font-semibold uppercase tracking-[0.25em] text-[#73CFE6]">
            FantaGol
          </p>

          <h1 className="mt-3 text-3xl font-black sm:text-4xl">
            Leghe pubbliche
          </h1>

          <p className="mt-4 leading-7 text-gray-400">
            Scopri le leghe disponibili, scegli quella che preferisci ed entra
            direttamente nel gioco.
          </p>
        </div>

        {loading && (
          <div className="mx-auto mt-12 flex max-w-md flex-col items-center rounded-3xl border border-white/10 bg-[#111417] p-8 text-center">
            <div className="h-9 w-9 animate-spin rounded-full border-2 border-white/15 border-t-[#73CFE6]" />

            <p className="mt-4 text-sm text-gray-400">
              Caricamento delle leghe pubbliche...
            </p>
          </div>
        )}

        {!loading && catalogError && (
          <div className="mx-auto mt-12 max-w-xl rounded-3xl border border-red-500/30 bg-red-500/10 p-7 text-center">
            <h2 className="text-xl font-black">
              Impossibile caricare il catalogo
            </h2>

            <p role="alert" className="mt-3 text-sm leading-6 text-red-200">
              {catalogError}
            </p>

            <button
              type="button"
              onClick={() => setRefreshKey((current) => current + 1)}
              className="mt-6 rounded-xl bg-[#73CFE6] px-5 py-3 text-sm font-black text-black transition hover:brightness-110"
            >
              Riprova
            </button>
          </div>
        )}

        {!loading && !catalogError && leagues.length === 0 && (
          <div className="mx-auto mt-12 max-w-xl rounded-3xl border border-white/10 bg-[#111417] p-8 text-center">
            <h2 className="text-2xl font-black">
              Nessuna lega pubblica disponibile
            </h2>

            <p className="mt-3 text-sm leading-6 text-gray-400">
              Puoi essere il primo a crearne una.
            </p>
          </div>
        )}

        {!loading && !catalogError && leagues.length > 0 && (
          <div className="mt-10 grid gap-5 md:grid-cols-2">
            {leagues.map((league) => {
              const firstKickoff = formatDateTime(
                league.first_useful_kickoff_at,
              );
              const isJoining = joiningLeagueId === league.league_id;
              const isJoinFormOpen = selectedLeagueId === league.league_id;

              const capacity =
                Number.isFinite(league.max_participants) &&
                league.max_participants > 0
                  ? league.max_participants
                  : 8;

              const activeMemberCount = Number.isFinite(
                league.active_member_count,
              )
                ? league.active_member_count
                : 0;

              const availableSlots = Math.max(
                Number.isFinite(league.available_slots)
                  ? league.available_slots
                  : capacity - activeMemberCount,
                0,
              );

              const joinStatusLabel =
                league.join_status === "open"
                  ? "Iscrizioni aperte"
                  : league.join_status === "full"
                    ? "Lega completa"
                    : league.join_status === "started"
                      ? "Campionato iniziato"
                      : "Iscrizioni chiuse";

              const joinStatusClassName =
                league.join_status === "open"
                  ? "bg-[#73CFE6]/15 text-[#73CFE6]"
                  : league.join_status === "full"
                    ? "bg-amber-500/15 text-amber-300"
                    : league.join_status === "started"
                      ? "bg-blue-500/15 text-blue-300"
                      : "bg-white/10 text-gray-300";

              const unavailableActionLabel =
                league.join_status === "full"
                  ? "Lega completa"
                  : league.join_status === "started"
                    ? "Campionato iniziato"
                    : "Iscrizioni chiuse";

              return (
                <article
                  key={league.league_id}
                  className="flex flex-col rounded-3xl border border-white/10 bg-gradient-to-b from-[#1f2427] to-[#0d0d0d] p-6 shadow-xl shadow-black/40"
                >
                  <div className="flex items-start justify-between gap-4">
                    <div>
                      <p className="text-xs font-bold uppercase tracking-[0.18em] text-[#73CFE6]">
                        {league.edition_label}
                      </p>

                      <h2 className="mt-2 text-2xl font-black">
                        {league.league_name}
                      </h2>
                    </div>

                    <span
                      className={`shrink-0 rounded-full px-3 py-1 text-xs font-bold ${joinStatusClassName}`}
                    >
                      {joinStatusLabel}
                    </span>
                  </div>

                  <dl className="mt-6 grid gap-4 text-sm sm:grid-cols-2">
                    <div>
                      <dt className="text-gray-500">Amministratore</dt>
                      <dd className="mt-1 font-semibold text-white">
                        {league.admin_display_name}
                      </dd>
                    </div>

                    <div>
                      <dt className="text-gray-500">Partecipanti</dt>
                      <dd className="mt-1 font-semibold text-white">
                        {activeMemberCount} / {capacity}
                      </dd>

                      <p className="mt-1 text-xs text-gray-500">
                        {availableSlots === 0
                          ? "Nessun posto disponibile"
                          : availableSlots === 1
                            ? "1 posto disponibile"
                            : `${availableSlots} posti disponibili`}
                      </p>
                    </div>

                    {league.starts_from_round_name && (
                      <div>
                        <dt className="text-gray-500">Giornata iniziale</dt>
                        <dd className="mt-1 font-semibold text-white">
                          {league.starts_from_round_name}
                        </dd>
                      </div>
                    )}

                    {firstKickoff && (
                      <div>
                        <dt className="text-gray-500">
                          Primo calcio d&apos;inizio
                        </dt>
                        <dd className="mt-1 font-semibold text-white">
                          {firstKickoff}
                        </dd>
                      </div>
                    )}
                  </dl>

                  <div className="mt-auto pt-6">
                    {league.viewer_is_member ? (
                      <button
                        type="button"
                        onClick={() => openLeague(league.league_id)}
                        className="w-full rounded-xl bg-[#73CFE6] px-5 py-3 font-black text-black transition hover:brightness-110"
                      >
                        Apri lega
                      </button>
                    ) : league.viewer_can_join ? (
                      isJoinFormOpen ? (
                        <div className="rounded-2xl border border-[#73CFE6]/25 bg-[#73CFE6]/5 p-4">
                          <label
                            htmlFor={`display-name-${league.league_id}`}
                            className="block text-sm font-semibold text-gray-200"
                          >
                            Il tuo nome nella lega
                          </label>

                          <input
                            id={`display-name-${league.league_id}`}
                            type="text"
                            maxLength={60}
                            autoFocus
                            value={displayName}
                            onChange={(event) =>
                              setDisplayName(event.target.value)
                            }
                            onKeyDown={(event) => {
                              if (event.key === "Enter") {
                                event.preventDefault();
                                void joinLeague(league.league_id);
                              }
                            }}
                            placeholder="Es. Cesare"
                            className="mt-3 w-full rounded-xl border border-gray-700 bg-black px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#73CFE6]"
                          />

                          {joinError && (
                            <p
                              role="alert"
                              className="mt-3 text-sm leading-6 text-red-200"
                            >
                              {joinError}
                            </p>
                          )}

                          <div className="mt-4 grid gap-3 sm:grid-cols-2">
                            <button
                              type="button"
                              disabled={isJoining}
                              onClick={cancelJoin}
                              className="rounded-xl border border-gray-600 px-4 py-3 text-sm font-bold text-gray-200 transition hover:border-gray-400 disabled:cursor-not-allowed disabled:opacity-60"
                            >
                              Annulla
                            </button>

                            <button
                              type="button"
                              disabled={isJoining}
                              onClick={() => void joinLeague(league.league_id)}
                              className="rounded-xl bg-[#73CFE6] px-4 py-3 text-sm font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-60"
                            >
                              {isJoining
                                ? "Ingresso in corso..."
                                : "Conferma ingresso"}
                            </button>
                          </div>
                        </div>
                      ) : (
                        <button
                          type="button"
                          onClick={() => startJoin(league.league_id)}
                          className="w-full rounded-xl bg-[#73CFE6] px-5 py-3 font-black text-black transition hover:brightness-110"
                        >
                          Entra
                        </button>
                      )
                    ) : (
                      <button
                        type="button"
                        disabled
                        className="w-full cursor-not-allowed rounded-xl border border-gray-700 bg-white/5 px-5 py-3 font-bold text-gray-500"
                      >
                        {unavailableActionLabel}
                      </button>
                    )}
                  </div>
                </article>
              );
            })}
          </div>
        )}

        {!loading && !catalogError && (
          <div className="mt-12 border-t border-white/10 pt-10 text-center">
            <button
              type="button"
              onClick={() => window.location.assign("/crea-lega/pubblica")}
              className="rounded-xl border border-[#73CFE6]/60 px-6 py-3 font-black text-[#73CFE6] transition hover:border-[#73CFE6] hover:bg-[#73CFE6]/10"
            >
              Crea nuova lega pubblica
            </button>
          </div>
        )}
      </section>
    </main>
  );
}
