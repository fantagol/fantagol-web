"use client";

import { useEffect, useState } from "react";
import Header from "../../components/Header";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

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

export default function DownloadPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [authResolved, setAuthResolved] = useState(false);
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [league, setLeague] = useState<DrawerLeague | null>(null);

  useEffect(() => {
    let active = true;

    async function loadAuthenticatedNavigation() {
      try {
        const {
          data: { session },
        } = await supabase.auth.getSession();

        if (!active) return;

        if (!session?.user) {
          setIsAuthenticated(false);
          setLeague(null);
          setAuthResolved(true);
          return;
        }

        setIsAuthenticated(true);

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
              inviteCode: current.invite_code || "",
              displayName: current.display_name || "Giocatore",
              role: current.role || "member",
            });
          } else {
            setLeague(null);
          }
        } else {
          console.error(
            "Unable to load authenticated download navigation:",
            error,
          );
          setLeague(null);
        }

        setAuthResolved(true);
      } catch (error) {
        console.error(
          "Unexpected authenticated download navigation error:",
          error,
        );

        if (!active) return;

        setIsAuthenticated(false);
        setLeague(null);
        setAuthResolved(true);
      }
    }

    void loadAuthenticatedNavigation();

    return () => {
      active = false;
    };
  }, []);

  return (
    <main className="min-h-screen bg-black text-white">
      {authResolved && (!isAuthenticated || !league) && <Header />}

      {isAuthenticated && league && (
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
              <div className="relative z-10 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
                <FantaGolLogo />
              </div>

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

      {!authResolved ? (
        <div className="flex min-h-screen items-center justify-center px-6">
          <p className="text-sm font-semibold uppercase tracking-[0.18em] text-gray-500">
            Caricamento...
          </p>
        </div>
      ) : (
        <div
          className={`flex items-center justify-center px-6 ${
            isAuthenticated && league ? "pb-32 pt-36" : "py-32"
          }`}
        >
          <div className="w-full max-w-3xl text-center">
            <h1 className="mb-6 text-5xl font-black sm:text-6xl">
              Scarica l&apos;app
            </h1>

            <p className="mb-10 text-xl text-gray-400">
              Le applicazioni ufficiali FantaGol arriveranno presto.
            </p>

            <div className="flex flex-col justify-center gap-4 md:flex-row">
              <a
                href="/download/android"
                className="rounded-xl border border-gray-700 px-8 py-4 font-bold transition hover:border-[#A6E824] hover:text-[#A6E824]"
              >
                Android — Coming Soon
              </a>

              <a
                href="/download/iphone"
                className="rounded-xl border border-gray-700 px-8 py-4 font-bold transition hover:border-[#A6E824] hover:text-[#A6E824]"
              >
                iPhone — Coming Soon
              </a>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}