"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

type ArchivedLeagueRow = {
  membership_id: string;
  league_id: string;
  league_name: string;
  display_name: string;
  role: string;
  membership_status: string;
  lifecycle_status: string;
  archived_at: string | null;
  archive_reason: string | null;
  edition_id: string | null;
  season_label: string;
  competition_name: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
};

type LeagueInfo = {
  leagueId: string;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

function formatArchivedAt(value: string | null) {
  if (!value) return "Data di chiusura non disponibile";

  return new Intl.DateTimeFormat("it-IT", {
    day: "2-digit",
    month: "long",
    year: "numeric",
  }).format(new Date(value));
}

function ArchiveIcon() {
  return (
    <span className="relative flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl border border-[#A6E824]/30 bg-[#A6E824]/10">
      <span className="relative h-7 w-7">
        <span className="absolute inset-x-0 top-0 h-2 rounded-t-md border border-[#A6E824]/80 bg-[#A6E824]/15" />
        <span className="absolute inset-x-0 bottom-0 top-2 rounded-b-md border border-t-0 border-[#A6E824]/70">
          <span className="absolute left-1/2 top-2 h-0.5 w-3 -translate-x-1/2 rounded bg-[#A6E824]" />
        </span>
      </span>
    </span>
  );
}

export default function ArchivioPage() {
  const router = useRouter();
  const [menuOpen, setMenuOpen] = useState(false);
  const [leagues, setLeagues] = useState<ArchivedLeagueRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueId: "",
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    let cancelled = false;

    async function loadArchive() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (cancelled) return;

      if (!session?.user) {
        window.location.replace("/login");
        return;
      }

      const [archiveResult, activeLeaguesResult] = await Promise.all([
        supabase.rpc("get_my_archived_leagues_rpc"),
        supabase.rpc("get_my_leagues_rpc"),
      ]);

      if (cancelled) return;

      if (!activeLeaguesResult.error) {
        const activeLeagues =
          (activeLeaguesResult.data || []) as MyLeagueRpcRow[];
        const rememberedLeagueId =
          window.localStorage.getItem(LAST_LEAGUE_STORAGE_KEY) || "";

        const selectedLeague =
          activeLeagues.find(
            (league) => league.league_id === rememberedLeagueId,
          ) || activeLeagues[0];

        if (selectedLeague?.league_id) {
          window.localStorage.setItem(
            LAST_LEAGUE_STORAGE_KEY,
            selectedLeague.league_id,
          );

          setLeagueInfo({
            leagueId: selectedLeague.league_id,
            leagueName:
              selectedLeague.league_name || "Lega FantaGol",
            displayName:
              selectedLeague.display_name || "Club FantaGol",
            inviteCode:
              selectedLeague.invite_code ||
              selectedLeague.league_id,
            role: selectedLeague.role || "member",
          });
        }
      }

      if (archiveResult.error) {
        setErrorMessage(archiveResult.error.message);
        setLoading(false);
        return;
      }

      setLeagues(
        (archiveResult.data || []) as ArchivedLeagueRow[],
      );
      setLoading(false);
    }

    void loadArchive();

    return () => {
      cancelled = true;
    };
  }, []);

  function openArchivedLeague(leagueId: string) {
    router.push(`/leghe/${leagueId}`);
  }

  return (
    <main className="min-h-screen bg-black pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="pointer-events-none absolute inset-x-0 bottom-0 z-0 border-b border-[#A6E824]/25" />

        <div className="mx-auto flex h-14 w-full max-w-6xl items-center justify-between overflow-visible px-4 md:px-6">
          <div className="pointer-events-none relative z-10 block min-w-0 -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
            <FantaGolLogo />
          </div>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className="relative z-10 shrink-0 rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
          >
            ☰
          </button>
        </div>
      </header>

      <HamburgerDrawer
        open={menuOpen}
        leagueName={leagueInfo.leagueName}
        displayName={leagueInfo.displayName}
        inviteCode={leagueInfo.inviteCode}
        role={leagueInfo.role}
        onClose={() => setMenuOpen(false)}
      />

      <section className="mx-auto max-w-6xl px-5 py-10 sm:px-6 sm:py-14">
        <button
          type="button"
          onClick={() =>
            router.push(
              leagueInfo.leagueId
                ? `/leghe/${leagueInfo.leagueId}`
                : "/leghe",
            )
          }
          className="text-sm font-black text-[#A6E824] transition hover:brightness-125"
        >
          ← Torna alla lega attiva
        </button>

        <div className="mt-8 flex items-start gap-4">
          <ArchiveIcon />

          <div>
            <p className="text-xs font-black uppercase tracking-[0.25em] text-[#A6E824]">
              Archivio FantaGol
            </p>
            <h1 className="mt-2 text-3xl font-black sm:text-4xl">
              Stagioni concluse
            </h1>
            <p className="mt-3 max-w-2xl text-sm leading-6 text-gray-400 sm:text-base">
              Ogni lega archiviata conserva definitivamente classifica,
              giornate, incontri, pronostici e statistiche della stagione
              conclusa.
            </p>
          </div>
        </div>

        {loading && (
          <div className="mt-10 rounded-3xl border border-white/10 bg-[#111417] p-8 text-center">
            <div className="mx-auto h-8 w-8 animate-spin rounded-full border-2 border-white/15 border-t-[#A6E824]" />
            <p className="mt-4 text-sm font-semibold text-gray-400">
              Caricamento archivio...
            </p>
          </div>
        )}

        {!loading && errorMessage && (
          <div className="mt-10 rounded-3xl border border-red-400/25 bg-red-500/10 p-6">
            <p className="font-black text-red-200">
              Impossibile caricare l&apos;archivio
            </p>
            <p className="mt-2 text-sm leading-6 text-red-100/80">
              {errorMessage}
            </p>
            <button
              type="button"
              onClick={() => window.location.reload()}
              className="mt-5 rounded-xl bg-[#A6E824] px-5 py-2.5 text-sm font-black text-black transition hover:brightness-110"
            >
              Riprova
            </button>
          </div>
        )}

        {!loading && !errorMessage && leagues.length === 0 && (
          <div className="mt-10 rounded-3xl border border-white/10 bg-gradient-to-br from-[#1b2023] to-[#0b0d0e] p-8 text-center shadow-2xl shadow-black/40">
            <div className="flex justify-center">
              <ArchiveIcon />
            </div>
            <h2 className="mt-5 text-2xl font-black">
              Nessuna stagione archiviata
            </h2>
            <p className="mx-auto mt-3 max-w-lg text-sm leading-6 text-gray-400">
              Le leghe compariranno qui automaticamente dopo la certificazione
              dell&apos;ultima partita e la chiusura definitiva del campionato.
            </p>
          </div>
        )}

        {!loading && !errorMessage && leagues.length > 0 && (
          <div className="mt-10 grid gap-5 md:grid-cols-2">
            {leagues.map((league) => (
              <button
                key={league.membership_id}
                type="button"
                onClick={() => openArchivedLeague(league.league_id)}
                className="group rounded-3xl border border-white/10 bg-gradient-to-br from-[#20272a] via-[#121618] to-[#090a0b] p-6 text-left shadow-xl shadow-black/30 transition hover:-translate-y-0.5 hover:border-[#A6E824]/60 hover:shadow-[0_0_30px_rgba(166,232,36,0.08)]"
              >
                <div className="flex items-start justify-between gap-4">
                  <ArchiveIcon />
                  <span className="rounded-full border border-[#A6E824]/30 bg-[#A6E824]/10 px-3 py-1 text-[10px] font-black uppercase tracking-[0.15em] text-[#A6E824]">
                    Definitiva
                  </span>
                </div>

                <h2 className="mt-5 text-2xl font-black text-white">
                  {league.league_name}
                </h2>

                <p className="mt-2 font-black text-[#A6E824]">
                  {league.competition_name} · {league.season_label}
                </p>

                <div className="mt-5 space-y-2 text-sm text-gray-400">
                  <p>
                    Club:{" "}
                    <span className="font-bold text-gray-200">
                      {league.display_name}
                    </span>
                  </p>
                  <p>
                    Archiviata il{" "}
                    <span className="font-bold text-gray-200">
                      {formatArchivedAt(league.archived_at)}
                    </span>
                  </p>
                </div>

                <div className="mt-6 flex items-center justify-between border-t border-white/10 pt-4">
                  <span className="text-xs font-black uppercase tracking-[0.16em] text-gray-500">
                    Sola lettura
                  </span>
                  <span className="font-black text-[#A6E824] transition group-hover:translate-x-1">
                    Apri archivio →
                  </span>
                </div>
              </button>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}
