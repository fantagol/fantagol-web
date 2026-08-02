"use client";

import { useEffect, useRef, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

type CreatePrivateLeagueResult = {
  league_id: string;
  invite_code: string;
  visibility: "private";
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

export default function CreaLegaPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [navigationResolved, setNavigationResolved] = useState(false);
  const [league, setLeague] = useState<DrawerLeague | null>(null);
  const [leagueName, setLeagueName] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [loading, setLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");
  const [inviteValue, setInviteValue] = useState("");
  const [inviteErrorMessage, setInviteErrorMessage] = useState("");
  const [privateHelpVisible, setPrivateHelpVisible] = useState(false);
  const privateFormRef = useRef<HTMLFormElement | null>(null);
  const leagueNameInputRef = useRef<HTMLInputElement | null>(null);

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
    window.location.replace(`/leghe/${result.league_id}`);
  }

  function handleSelectPrivateLeague() {
    setPrivateHelpVisible(true);

    window.requestAnimationFrame(() => {
      privateFormRef.current?.scrollIntoView({
        behavior: "smooth",
        block: "start",
      });

      window.setTimeout(() => {
        leagueNameInputRef.current?.focus();
      }, 350);
    });
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
                className="rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
              >
                ☰
              </button>
            </div>
          </header>
        </>
      )}

      <section className="mx-auto flex min-h-screen max-w-6xl items-center justify-center px-6 pb-16 pt-24">
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
            <button
              type="button"
              onClick={handleSelectPrivateLeague}
              aria-controls="private-league-form"
              className="rounded-2xl border border-[#A6E824] bg-[#A6E824]/10 p-5 text-left transition hover:bg-[#A6E824]/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#A6E824] focus-visible:ring-offset-2 focus-visible:ring-offset-black"
            >
              <span className="block font-bold text-white">Privata</span>

              <span className="mt-2 block text-sm leading-6 text-gray-400">
                Partecipano soltanto gli utenti che ricevono il link di invito.
              </span>

              <span className="mt-3 block text-xs font-semibold uppercase tracking-[0.14em] text-[#A6E824]">
                
              </span>
            </button>

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

          {privateHelpVisible && (
            <div
              role="status"
              className="mb-6 rounded-xl border border-[#A6E824]/35 bg-[#A6E824]/10 px-4 py-3 text-sm leading-6 text-gray-200"
            >
              Compila i campi qui sotto per creare la tua lega privata. Dopo la
              creazione riceverai il link da condividere con gli altri
              partecipanti.
            </div>
          )}

          <form
            id="private-league-form"
            ref={privateFormRef}
            onSubmit={handleCreateLeague}
            className="scroll-mt-24 space-y-6"
          >
            <div>
              <label
                htmlFor="league-name"
                className="mb-2 block text-sm font-semibold text-gray-300"
              >
                Nome lega
              </label>

              <input
                id="league-name"
                ref={leagueNameInputRef}
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
          <section className="mt-8 border-t border-gray-700 pt-8">
            <p className="text-sm font-semibold uppercase tracking-[0.18em] text-[#A6E824]">
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
                  className="min-w-0 flex-1 rounded-xl border border-gray-700 bg-[#111111] px-4 py-3 text-white outline-none transition placeholder:text-gray-500 focus:border-[#A6E824]"
                />

                <button
                  type="submit"
                  className="shrink-0 rounded-xl border border-[#A6E824]/60 bg-[#A6E824]/10 px-5 py-3 font-semibold text-[#A6E824] transition hover:border-[#A6E824] hover:bg-[#A6E824]/15"
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
