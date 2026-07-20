"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";

import Badge from "../../../../components/ui/Badge";
import DashboardCard from "../../../../components/ui/DashboardCard";
import { supabase } from "../../../../lib/supabaseClient";

type LeagueInfo = {
  id: string;
  name: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

function translateDeleteError(message: string): string {
  if (message.includes("ACTIVE_ADMIN_REQUIRED")) {
    return "Solo l'admin della lega può eliminarla definitivamente.";
  }

  if (message.includes("LEAGUE_NAME_CONFIRMATION_MISMATCH")) {
    return "Il nome inserito non corrisponde al nome della lega.";
  }

  if (message.includes("LEAGUE_NOT_FOUND")) {
    return "La lega non esiste più oppure non è accessibile.";
  }

  if (message.includes("AUTH_REQUIRED")) {
    return "La sessione è scaduta. Accedi nuovamente.";
  }

  return message || "Eliminazione definitiva della lega non riuscita.";
}


type MyLeagueRpcRow = {
  league_id: string;
  membership_id?: string | null;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
  status?: string | null;
};

export default function LeagueSettingsPage() {
  const params = useParams<{ id: string }>();
  const router = useRouter();
  const leagueId = params.id;

  const [league, setLeague] = useState<LeagueInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [confirmationName, setConfirmationName] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function loadSettings() {
      setLoading(true);
      setErrorMessage(null);

      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (cancelled) return;

      if (!session?.user) {
        router.replace("/login");
        return;
      }

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");

      if (cancelled) return;

      if (error) {
        setErrorMessage(error.message);
        setLoading(false);
        return;
      }

      const current = (data || []).find(
        (row: MyLeagueRpcRow) => row.league_id === leagueId
      );

      if (!current) {
        router.replace("/leghe");
        return;
      }

      setLeague({
        id: current.league_id,
        name: current.league_name || "Lega FantaGol",
        displayName: current.display_name || "Club FantaGol",
        inviteCode: current.invite_code || leagueId,
        role: current.role || "member",
      });

      setLoading(false);
    }

    void loadSettings();

    return () => {
      cancelled = true;
    };
  }, [leagueId, router]);

  const isAdmin = league?.role === "admin";
  const confirmationMatches =
    Boolean(league) && confirmationName === league?.name;

  async function permanentlyDeleteLeague() {
    if (
      !league ||
      !isAdmin ||
      !confirmationMatches ||
      deleting
    ) {
      return;
    }

    setDeleting(true);
    setErrorMessage(null);

    const { error } = await supabase.rpc(
      "delete_league_permanently_rpc",
      {
        p_league_id: league.id,
        p_confirmation_name: confirmationName,
      }
    );

    if (error) {
      setDeleting(false);
      setErrorMessage(translateDeleteError(error.message));
      return;
    }

    router.replace("/leghe");
    router.refresh();
  }

  if (loading) {
    return (
      <main className="flex min-h-[calc(100vh-3.5rem)] items-center justify-center bg-black px-4 text-white">
        <div className="rounded-2xl border border-white/10 bg-[#111417] px-6 py-5 text-center shadow-2xl shadow-black/60">
          <div className="mx-auto h-8 w-8 animate-spin rounded-full border-2 border-white/10 border-t-[#A6E824]" />

          <p className="mt-4 text-sm font-black text-gray-300">
            Caricamento impostazioni...
          </p>
        </div>
      </main>
    );
  }

  if (!league) return null;

  return (
    <main className="min-h-[calc(100vh-3.5rem)] bg-black text-white">
      <section className="mx-auto max-w-5xl px-4 py-6 sm:py-8">
        <DashboardCard className="border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] shadow-2xl shadow-black/70">
          <div className="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between">
            <div className="min-w-0">
              <p className="text-xs font-black uppercase tracking-[0.22em] text-[#A6E824]">
                {league.name}
              </p>

              <h1 className="mt-3 text-3xl font-black sm:text-4xl">
                Impostazioni
              </h1>

              <p className="mt-3 max-w-2xl text-sm font-semibold leading-6 text-gray-400 sm:text-base">
                Gestisci le funzioni amministrative della lega.
              </p>
            </div>

            <Badge variant={isAdmin ? "success" : undefined}>
              {isAdmin ? "Admin" : league.role}
            </Badge>
          </div>
        </DashboardCard>

        <DashboardCard className="mt-6 border-red-500/30 bg-gradient-to-br from-red-950/25 via-[#15191b] to-[#080909] shadow-2xl shadow-black/70">
          <div className="flex items-start gap-4">
            <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl border border-red-400/35 bg-red-500/10 text-2xl font-black text-red-400 shadow-[0_0_18px_rgba(239,68,68,0.12)]">
              !
            </div>

            <div className="min-w-0">
              <p className="text-xs font-black uppercase tracking-[0.2em] text-red-400">
                Zona pericolosa
              </p>

              <h2 className="mt-2 text-xl font-black text-white sm:text-2xl">
                Elimina definitivamente la lega
              </h2>

              <p className="mt-3 text-sm font-semibold leading-6 text-gray-400">
                La cancellazione elimina la lega e tutti i dati collegati.
                Questa operazione non può essere annullata.
              </p>
            </div>
          </div>

          <div className="mt-6 border-t border-white/10 pt-6">
            {!isAdmin ? (
              <div className="rounded-2xl border border-white/10 bg-black/35 p-5">
                <p className="font-black text-white">
                  Funzione riservata all&apos;admin
                </p>

                <p className="mt-2 text-sm font-semibold leading-6 text-gray-500">
                  Soltanto l&apos;admin della lega può eseguire la cancellazione
                  definitiva.
                </p>
              </div>
            ) : (
              <>
                <div className="rounded-2xl border border-red-500/20 bg-black/30 p-4 sm:p-5">
                  <p className="text-sm font-semibold leading-6 text-gray-300">
                    Per autorizzare la cancellazione, inserisci esattamente il
                    nome della lega:
                  </p>

                  <div className="mt-3 rounded-xl border border-white/10 bg-[#0b0d0e] px-4 py-3 font-black text-white">
                    {league.name}
                  </div>
                </div>

                <label
                  htmlFor="league-delete-confirmation"
                  className="mt-5 block text-xs font-black uppercase tracking-[0.15em] text-gray-400"
                >
                  Conferma nome lega
                </label>

                <input
                  id="league-delete-confirmation"
                  type="text"
                  value={confirmationName}
                  onChange={(event) => {
                    setConfirmationName(event.target.value);
                    setErrorMessage(null);
                  }}
                  autoComplete="off"
                  spellCheck={false}
                  disabled={deleting}
                  placeholder={league.name}
                  className="mt-2 w-full rounded-2xl border border-white/10 bg-black/40 px-4 py-4 font-bold text-white outline-none transition placeholder:text-gray-700 focus:border-red-400/70 focus:ring-2 focus:ring-red-500/10 disabled:cursor-not-allowed disabled:opacity-60"
                />

                {confirmationName.length > 0 && !confirmationMatches && (
                  <p className="mt-2 text-xs font-bold text-red-300">
                    Il nome inserito non corrisponde.
                  </p>
                )}

                {errorMessage && (
                  <div className="mt-4 rounded-2xl border border-red-500/30 bg-red-950/25 px-4 py-3 text-sm font-semibold text-red-200">
                    {errorMessage}
                  </div>
                )}

                <button
                  type="button"
                  onClick={permanentlyDeleteLeague}
                  disabled={!confirmationMatches || deleting}
                  className="mt-6 w-full rounded-2xl border border-red-400/40 bg-red-600 px-6 py-4 font-black text-white shadow-lg shadow-red-950/30 transition hover:-translate-y-0.5 hover:bg-red-500 hover:brightness-110 focus:outline-none focus:ring-2 focus:ring-red-400/70 focus:ring-offset-2 focus:ring-offset-black disabled:cursor-not-allowed disabled:border-white/10 disabled:bg-[#202426] disabled:text-gray-600 disabled:shadow-none disabled:hover:translate-y-0 disabled:hover:brightness-100"
                >
                  {deleting
                    ? "Eliminazione in corso..."
                    : "Elimina definitivamente la lega"}
                </button>
              </>
            )}
          </div>
        </DashboardCard>
      </section>
    </main>
  );
}
