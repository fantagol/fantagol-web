"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import Header from "../../components/Header";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import {
  cancelMyAccountDeletion,
  getMyAccountDeletionFrontendState,
  getPublicAccountDeletionPolicy,
  requestMyAccountDeletion,
  requestReauthGrant,
} from "../../lib/account-lifecycle/client";
import type {
  AccountDeletionFrontendState,
  AccountDeletionPolicy,
} from "../../lib/account-lifecycle/types";
import { useNativeAppMode } from "../../lib/platform/app-mode";
import { supabase } from "../../lib/supabaseClient";

const OAUTH_REAUTH_PENDING_KEY =
  "fantagol.accountDeletion.oauthReauthPending.v1";
const PENDING_AUTH_DESTINATION_KEY =
  "fantagol.pendingAuthDestination.v1";
const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

type DrawerLeague = {
  id: string;
  name: string;
  inviteCode: string;
  displayName: string;
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

function formatDate(value: string | null) {
  if (!value) return "Non disponibile";

  return new Intl.DateTimeFormat("it-IT", {
    dateStyle: "long",
    timeStyle: "short",
  }).format(new Date(value));
}

function getErrorMessage(error: unknown) {
  if (error instanceof Error) return error.message;
  return "Operazione non riuscita.";
}

export default function DeleteAccountPage() {
  const isNativeApp = useNativeAppMode();
  const [loading, setLoading] = useState(true);
  const [authenticated, setAuthenticated] = useState(false);
  const [provider, setProvider] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const [league, setLeague] = useState<DrawerLeague | null>(null);
  const [policy, setPolicy] =
    useState<AccountDeletionPolicy | null>(null);
  const [state, setState] =
    useState<AccountDeletionFrontendState | null>(null);
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [reauthGrant, setReauthGrant] = useState("");
  const [reauthExpiresAt, setReauthExpiresAt] = useState("");
  const [busy, setBusy] = useState<
    "reauth" | "request" | "cancel" | null
  >(null);
  const [errorMessage, setErrorMessage] = useState("");
  const [successMessage, setSuccessMessage] = useState("");

  const passwordAccount = provider === "email";
  const hasValidGrant =
    Boolean(reauthGrant) &&
    Boolean(reauthExpiresAt) &&
    new Date(reauthExpiresAt).getTime() > Date.now();

  const confirmationMatches =
    confirmation === (state?.confirmation_phrase || "ELIMINA");

  const requestOpen = Boolean(state?.has_open_request);

  const remainingDays = useMemo(() => {
    const seconds = state?.cooling_off_seconds_remaining || 0;
    return Math.ceil(seconds / 86400);
  }, [state?.cooling_off_seconds_remaining]);

  async function loadContext() {
    setLoading(true);
    setErrorMessage("");

    try {
      const publicPolicy = await getPublicAccountDeletionPolicy();
      setPolicy(publicPolicy);

      const {
        data: { session },
        error,
      } = await supabase.auth.getSession();

      if (error) throw error;

      if (!session?.user) {
        setAuthenticated(false);
        setState(null);
        return;
      }

      setAuthenticated(true);
      setProvider(
        typeof session.user.app_metadata?.provider === "string"
          ? session.user.app_metadata.provider
          : "email",
      );

      const { data: leagueData, error: leagueError } =
        await supabase.rpc("get_my_leagues_rpc");

      if (leagueError) throw leagueError;

      const leagueRows = (leagueData || []) as MyLeagueRpcRow[];
      const rememberedLeagueId = window.localStorage.getItem(
        LAST_LEAGUE_STORAGE_KEY,
      );

      const selectedLeague =
        leagueRows.find(
          (row) =>
            row.league_id === rememberedLeagueId &&
            row.status !== "removed",
        ) ||
        leagueRows.find((row) => row.status !== "removed") ||
        null;

      setLeague(
        selectedLeague
          ? {
              id: selectedLeague.league_id,
              name: selectedLeague.league_name || "Lega FantaGol",
              inviteCode:
                selectedLeague.invite_code || selectedLeague.league_id,
              displayName:
                selectedLeague.display_name || "Club FantaGol",
              role: selectedLeague.role || "member",
            }
          : null,
      );

      const frontendState =
        await getMyAccountDeletionFrontendState();
      setState(frontendState);
    } catch (error) {
      setErrorMessage(getErrorMessage(error));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadContext();
  }, []);

  useEffect(() => {
    if (!authenticated) return;

    const search = new URLSearchParams(window.location.search);
    const oauthReturned = search.get("reauth") === "oauth";
    const pending =
      window.sessionStorage.getItem(OAUTH_REAUTH_PENDING_KEY) === "1";

    if (!oauthReturned || !pending) return;

    window.sessionStorage.removeItem(OAUTH_REAUTH_PENDING_KEY);
    window.history.replaceState(null, "", "/elimina-account");
    setBusy("reauth");

    void requestReauthGrant({ mode: "oauth_recent" })
      .then((grant) => {
        setReauthGrant(grant.grantToken);
        setReauthExpiresAt(grant.expiresAt);
        setSuccessMessage(
          "Identità verificata. Ora digita ELIMINA per confermare.",
        );
      })
      .catch((error) => {
        setErrorMessage(getErrorMessage(error));
      })
      .finally(() => setBusy(null));
  }, [authenticated]);

  async function handlePasswordReauth(
    event: FormEvent<HTMLFormElement>,
  ) {
    event.preventDefault();
    if (busy || !password) return;

    setBusy("reauth");
    setErrorMessage("");
    setSuccessMessage("");

    try {
      const grant = await requestReauthGrant({
        mode: "password",
        password,
      });

      setReauthGrant(grant.grantToken);
      setReauthExpiresAt(grant.expiresAt);
      setPassword("");
      setSuccessMessage(
        "Password verificata. Ora digita ELIMINA per confermare.",
      );
    } catch (error) {
      setErrorMessage(getErrorMessage(error));
    } finally {
      setBusy(null);
    }
  }

  async function handleOAuthReauth() {
    if (busy) return;

    setBusy("reauth");
    setErrorMessage("");
    setSuccessMessage("");

    window.sessionStorage.setItem(OAUTH_REAUTH_PENDING_KEY, "1");
    window.localStorage.setItem(
      PENDING_AUTH_DESTINATION_KEY,
      "/elimina-account?reauth=oauth",
    );

    const { error } = await supabase.auth.signInWithOAuth({
      provider: provider === "google" ? "google" : "google",
      options: {
        redirectTo: `${window.location.origin}/auth/callback?returnTo=${encodeURIComponent(
          "/elimina-account?reauth=oauth",
        )}`,
        queryParams: {
          prompt: "select_account",
        },
      },
    });

    if (error) {
      window.sessionStorage.removeItem(OAUTH_REAUTH_PENDING_KEY);
      setBusy(null);
      setErrorMessage(error.message);
    }
  }

  async function handleRequestDeletion() {
    if (
      busy ||
      !hasValidGrant ||
      !confirmationMatches ||
      !state
    ) {
      return;
    }

    setBusy("request");
    setErrorMessage("");
    setSuccessMessage("");

    try {
      const nextState = await requestMyAccountDeletion({
        confirmationPhrase: confirmation,
        reauthGrantToken: reauthGrant,
        requestChannel: isNativeApp
          ? "android_app"
          : "authenticated_web",
      });

      setState(nextState);
      setReauthGrant("");
      setReauthExpiresAt("");
      setConfirmation("");
      setSuccessMessage(
        "Richiesta registrata. Puoi annullarla durante il periodo di ripensamento.",
      );
    } catch (error) {
      setErrorMessage(getErrorMessage(error));
    } finally {
      setBusy(null);
    }
  }

  async function handleCancelDeletion() {
    if (busy || !state?.cancellation_allowed) return;

    const confirmed = window.confirm(
      "Vuoi annullare la richiesta di eliminazione dell’account?",
    );

    if (!confirmed) return;

    setBusy("cancel");
    setErrorMessage("");
    setSuccessMessage("");

    try {
      const nextState = await cancelMyAccountDeletion();
      setState(nextState);
      setSuccessMessage(
        "Richiesta annullata. Il tuo account resta attivo.",
      );
    } catch (error) {
      setErrorMessage(getErrorMessage(error));
    } finally {
      setBusy(null);
    }
  }

  const authenticatedHeader =
    authenticated && league ? (
      <>
        <HamburgerDrawer
          open={menuOpen}
          leagueName={league.name}
          displayName={league.displayName}
          inviteCode={league.inviteCode}
          role={league.role}
          onClose={() => setMenuOpen(false)}
        />

        <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
          <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
            <a
              href={`/leghe/${league.id}`}
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
              {"\u2630"}
            </button>
          </div>
        </header>
      </>
    ) : null;

  return (
    <main className="min-h-screen bg-black text-white">
      {!loading && !authenticated && <Header />}
      {authenticatedHeader}

      <div
        className={`mx-auto max-w-5xl px-5 pb-20 ${
          loading ? "pt-10" : "pt-24"
        }`}
      >
        <section className="rounded-3xl border border-red-500/25 bg-gradient-to-b from-[#241719] to-[#0d0d0d] p-6 shadow-2xl shadow-black/70 md:p-10">
          <p className="text-sm font-black uppercase tracking-[0.25em] text-red-400">
            Privacy e account
          </p>

          <h1 className="mt-4 text-4xl font-black md:text-5xl">
            Elimina account
          </h1>

          <p className="mt-4 max-w-3xl text-base leading-7 text-gray-300">
            La cancellazione è un processo governato: i dati personali
            vengono eliminati, lo storico competitivo viene anonimizzato
            e le evidenze economiche necessarie restano pseudonimizzate e
            accessibili solo in forma ristretta.
          </p>
        </section>

        <section className="mt-8 grid gap-4 md:grid-cols-2">
          {[
            ["Eliminati", "Profilo, avatar, sessioni, token e dati personali diretti."],
            ["Anonimizzati", "Club, membership e identità nello storico competitivo."],
            ["Conservati in forma ristretta", "Ledger, pagamenti e prove necessarie per integrità e obblighi applicabili."],
            ["Irreversibile", "Dopo l’inizio dell’erasure l’account non potrà essere recuperato."],
          ].map(([title, description]) => (
            <article
              key={title}
              className="rounded-2xl border border-white/10 bg-[#111417] p-5"
            >
              <h2 className="font-black text-white">{title}</h2>
              <p className="mt-2 text-sm leading-6 text-gray-400">
                {description}
              </p>
            </article>
          ))}
        </section>

        {loading && (
          <div className="mt-8 rounded-2xl border border-white/10 bg-[#111417] p-6 text-gray-300">
            Caricamento stato account...
          </div>
        )}

        {!loading && !authenticated && (
          <section className="mt-8 rounded-3xl border border-[#A6E824]/30 bg-[#111417] p-6">
            <h2 className="text-2xl font-black">
              Accedi per gestire la richiesta
            </h2>
            <p className="mt-3 text-sm leading-6 text-gray-400">
              Questa pagina resta pubblica e descrive il trattamento dei
              dati. Per richiedere o annullare la cancellazione devi
              autenticarti.
            </p>
            <a
              href="/login?returnTo=%2Felimina-account"
              className="mt-5 inline-flex rounded-xl bg-[#A6E824] px-5 py-3 font-black text-black"
            >
              Accedi a FantaGol
            </a>
          </section>
        )}

        {!loading && authenticated && state && (
          <>
            <section className="mt-8 rounded-3xl border border-white/10 bg-[#111417] p-6">
              <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
                Stato attuale
              </p>
              <h2 className="mt-2 text-2xl font-black">
                {requestOpen
                  ? "Eliminazione pianificata"
                  : "Account attivo"}
              </h2>

              {requestOpen ? (
                <div className="mt-5 space-y-3 text-sm leading-6 text-gray-300">
                  <p>
                    Richiesta registrata:{" "}
                    <strong>{formatDate(state.requested_at)}</strong>
                  </p>
                  <p>
                    Data pianificata:{" "}
                    <strong>{formatDate(state.scheduled_for)}</strong>
                  </p>
                  <p>
                    Giorni di ripensamento rimanenti:{" "}
                    <strong>{remainingDays}</strong>
                  </p>

                  <button
                    type="button"
                    disabled={
                      busy === "cancel" ||
                      !state.cancellation_allowed
                    }
                    onClick={() => void handleCancelDeletion()}
                    className="mt-3 w-full rounded-xl border border-[#A6E824]/50 px-5 py-3 font-black text-[#A6E824] disabled:opacity-50"
                  >
                    {busy === "cancel"
                      ? "Annullamento..."
                      : "Annulla richiesta"}
                  </button>
                </div>
              ) : (
                <p className="mt-3 text-sm leading-6 text-gray-400">
                  Nessuna richiesta di eliminazione è attiva.
                </p>
              )}
            </section>

            {!requestOpen && (
              <section className="mt-8 rounded-3xl border border-red-500/25 bg-[#111417] p-6">
                <p className="text-xs font-black uppercase tracking-[0.2em] text-red-400">
                  Conferma forte
                </p>

                <h2 className="mt-2 text-2xl font-black">
                  Verifica nuovamente la tua identità
                </h2>

                {passwordAccount ? (
                  <form
                    onSubmit={handlePasswordReauth}
                    className="mt-5"
                  >
                    <label className="text-sm font-bold text-gray-300">
                      Password account
                    </label>
                    <input
                      type="password"
                      value={password}
                      onChange={(event) =>
                        setPassword(event.target.value)
                      }
                      autoComplete="current-password"
                      className="mt-2 w-full rounded-xl border border-gray-700 bg-black px-4 py-3 outline-none focus:border-[#A6E824]"
                    />
                    <button
                      type="submit"
                      disabled={busy === "reauth" || !password}
                      className="mt-4 w-full rounded-xl bg-white px-5 py-3 font-black text-black disabled:opacity-50"
                    >
                      {busy === "reauth"
                        ? "Verifica..."
                        : "Verifica password"}
                    </button>
                  </form>
                ) : (
                  <button
                    type="button"
                    onClick={() => void handleOAuthReauth()}
                    disabled={busy === "reauth"}
                    className="mt-5 w-full rounded-xl bg-white px-5 py-3 font-black text-black disabled:opacity-50"
                  >
                    {busy === "reauth"
                      ? "Reindirizzamento..."
                      : "Verifica nuovamente con Google"}
                  </button>
                )}

                {hasValidGrant && (
                  <div className="mt-6 border-t border-white/10 pt-6">
                    <label className="text-sm font-bold text-gray-300">
                      Digita esattamente{" "}
                      <strong className="text-red-400">
                        {state.confirmation_phrase}
                      </strong>
                    </label>

                    <input
                      value={confirmation}
                      onChange={(event) =>
                        setConfirmation(event.target.value)
                      }
                      autoComplete="off"
                      spellCheck={false}
                      className="mt-2 w-full rounded-xl border border-red-500/40 bg-black px-4 py-3 font-black outline-none focus:border-red-400"
                    />

                    <button
                      type="button"
                      onClick={() => void handleRequestDeletion()}
                      disabled={
                        busy === "request" ||
                        !confirmationMatches
                      }
                      className="mt-4 w-full rounded-xl bg-red-600 px-5 py-4 font-black text-white disabled:bg-[#252525] disabled:text-gray-600"
                    >
                      {busy === "request"
                        ? "Registrazione richiesta..."
                        : "Richiedi eliminazione account"}
                    </button>
                  </div>
                )}
              </section>
            )}
          </>
        )}

        {errorMessage && (
          <div className="mt-6 rounded-2xl border border-red-500/40 bg-red-500/10 px-5 py-4 text-sm text-red-200">
            {errorMessage}
          </div>
        )}

        {successMessage && (
          <div className="mt-6 rounded-2xl border border-[#A6E824]/40 bg-[#A6E824]/10 px-5 py-4 text-sm text-[#D8FF86]">
            {successMessage}
          </div>
        )}

        <section className="mt-8 rounded-3xl border border-white/10 bg-[#111417] p-6">
          <h2 className="text-2xl font-black">Tempi e assistenza</h2>
          <p className="mt-3 text-sm leading-6 text-gray-400">
            Il periodo standard di ripensamento è di{" "}
            {Math.round((policy?.cooling_off_seconds || 0) / 86400)} giorni.
            Per casi particolari puoi utilizzare la pagina Supporto.
          </p>
          <a
            href="/supporto"
            className="mt-5 inline-flex rounded-xl border border-white/15 px-5 py-3 font-black text-white"
          >
            Vai al Supporto
          </a>
        </section>
      </div>
    </main>
  );
}
