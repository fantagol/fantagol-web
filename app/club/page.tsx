"use client";

import { useEffect, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import FantaGolModeIcon from "../../components/app/FantaGolModeIcon";
import KitPreview from "../../components/club/KitPreview";
import { supabase } from "../../lib/supabaseClient";
import {
  getMyLeagueHallOfFame,
  buildLeagueScopedClubPath,
  getMyLeagueIdentity,
  readLeagueIdFromLocation,
  resolveActiveLeagueId,
  type LeagueHallOfFame,
  type LeagueIdentity,
} from "../../lib/league-identity";

type Club = LeagueIdentity &
  Pick<
    LeagueHallOfFame,
    | "fantacalcio_titles"
    | "one_to_one_titles"
    | "punti_puri_titles"
  >;

type MyLeagueRow = {
  league_id: string;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
};

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

export default function ClubPage() {
  const [club, setClub] = useState<Club | null>(null);
  const [loading, setLoading] = useState(true);
  const [menuOpen, setMenuOpen] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadClub() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      try {
        const activeLeagueId =
          await resolveActiveLeagueId(
            supabase,
            readLeagueIdFromLocation(),
          );

        const [
          { data: leaguesData },
          identity,
          hallOfFame,
        ] = await Promise.all([
          supabase.rpc("get_my_leagues_rpc"),
          getMyLeagueIdentity(
            supabase,
            activeLeagueId,
          ),
          getMyLeagueHallOfFame(
            supabase,
            activeLeagueId,
          ),
        ]);

        const leagueRows = (leaguesData || []) as MyLeagueRow[];
        const activeLeague = leagueRows.find(
          (row) => row.league_id === activeLeagueId,
        );

        setLeagueInfo({
          leagueName:
            activeLeague?.league_name || "Lega FantaGol",
          displayName:
            identity.display_name || "Club FantaGol",
          inviteCode:
            activeLeague?.invite_code ||
            activeLeagueId,
          role:
            identity.membership_role ||
            activeLeague?.role ||
            "member",
        });

        if (
          hallOfFame.league_member_id !==
            identity.league_member_id ||
          hallOfFame.league_id !==
            identity.league_id
        ) {
          throw new Error(
            "I dati Hall of Fame non corrispondono al profilo della lega.",
          );
        }

        setClub({
          ...identity,
          stars_count:
            hallOfFame.stars_count,
          total_titles:
            hallOfFame.total_titles,
          fantacalcio_titles:
            hallOfFame.fantacalcio_titles,
          one_to_one_titles:
            hallOfFame.one_to_one_titles,
          punti_puri_titles:
            hallOfFame.punti_puri_titles,
        });
      } catch (error: unknown) {
        const message =
          error instanceof Error
            ? error.message
            : "Errore durante il caricamento del Club.";

        alert(message);
      } finally {
        setLoading(false);
      }
    }

    loadClub();
  }, []);

  useEffect(() => {
    if (loading) return;

    const params = new URLSearchParams(window.location.search);
    if (params.get("scrollTo") !== "hall-of-fame") return;

    const timer = window.setTimeout(() => {
      const el = document.getElementById("hall-of-fame");
      if (!el) return;

      el.scrollIntoView({ behavior: "smooth", block: "start" });
      window.history.replaceState(
        {},
        "",
        buildLeagueScopedClubPath(
          "/club",
          club?.league_id ||
            readLeagueIdFromLocation() ||
            "",
        ),
      );
    }, 250);

    return () => window.clearTimeout(timer);
  }, [loading, club?.league_id]);

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        Caricamento Club...
      </main>
    );
  }

  if (!club) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-black text-white">
        Club non trovato.
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-black pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
          <div className="pointer-events-none relative z-0 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
            <FantaGolLogo />
          </div>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className="rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
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

      <section className="mx-auto max-w-6xl px-6 py-10">
        <p className="text-sm font-semibold uppercase tracking-[0.3em] text-[#A6E824]">
          Il Mio Club
        </p>

        <h1 className="mt-3 text-5xl font-black">{club.club_name || club.display_name}</h1>

        <p className="mt-4 text-gray-400">
          {club.motto || "Il tuo Club FantaGol sta per iniziare la sua storia."}
        </p>

        <div className="mt-10 grid gap-6 lg:grid-cols-[380px_1fr]">
          <div className="rounded-3xl border border-gray-700 bg-gradient-to-b from-[#23282b] to-[#111111] p-8">
            <KitPreview
              primary={club.kit_primary_color}
              secondary={club.kit_secondary_color}
              third={club.kit_third_color}
              template={club.kit_template}
              logoMode={club.kit_logo_mode}
              crestPosition={club.kit_crest_position}
              starsCount={club.stars_count}
            />

            <p className="mt-6 text-center text-sm text-gray-400">
              Kit ufficiale del Club
            </p>
          </div>

          <div className="space-y-6">
            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
              <h2 id="hall-of-fame" className="text-2xl font-black scroll-mt-24">Hall of Fame</h2>

              <div className="mt-6 grid grid-cols-2 gap-4">
                <div className="rounded-2xl bg-black p-5">
                  <div className="text-sm text-gray-400">Stelle</div>
                  <div className="mt-2 text-4xl font-black text-[#A6E824]">
                    {club.stars_count}
                  </div>
                </div>

                <div className="rounded-2xl bg-black p-5">
                  <div className="text-sm text-gray-400">Titoli totali</div>
                  <div className="mt-2 text-4xl font-black text-[#A6E824]">
                    {club.total_titles}
                  </div>
                </div>
              </div>

              <div className="mt-5 grid gap-3">
                <div className="flex items-center justify-between rounded-2xl border border-gray-800 bg-black px-5 py-4">
                  <div>
                    <div className="flex items-center gap-2">
                      <FantaGolModeIcon
                        mode="fantacalcio"
                        className="h-8 w-8 rounded-lg"
                      />
                      <div className="font-black">Fantacalcio</div>
                    </div>
                    
                  </div>
                  <div className="text-2xl font-black text-[#A6E824]">
                    {club.fantacalcio_titles}
                  </div>
                </div>

                <div className="flex items-center justify-between rounded-2xl border border-gray-800 bg-black px-5 py-4">
                  <div>
                    <div className="flex items-center gap-2">
                      <FantaGolModeIcon
                        mode="one-to-one"
                        className="h-8 w-8 rounded-lg"
                      />
                      <div className="font-black">One to One</div>
                    </div>
                    
                  </div>
                  <div className="text-2xl font-black text-[#A6E824]">
                    {club.one_to_one_titles}
                  </div>
                </div>

                <div className="flex items-center justify-between rounded-2xl border border-gray-800 bg-black px-5 py-4">
                  <div>
                    <div className="flex items-center gap-2">
                      <FantaGolModeIcon
                        mode="punti-puri"
                        className="h-8 w-8 rounded-lg"
                      />
                      <div className="font-black">Punti Puri</div>
                    </div>
                    
                  </div>
                  <div className="text-2xl font-black text-[#A6E824]">
                    {club.punti_puri_titles}
                  </div>
                </div>
              </div>

              
            </div>

            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
             

              <div className="mt-6 space-y-4">
                <a
                  href={buildLeagueScopedClubPath(
                    "/club/kit",
                    club.league_id,
                  )}
                  className="block w-full rounded-2xl bg-[#A6E824] py-4 text-center font-bold text-black transition hover:brightness-110"
                >
                  Personalizza Kit
                </a>

                <a
                  href={buildLeagueScopedClubPath(
                    "/club/profilo",
                    club.league_id,
                  )}
                  className="block w-full rounded-2xl border border-gray-700 py-4 text-center font-bold transition hover:border-[#A6E824] hover:text-[#A6E824]"
                >
                  Profilo Club
                </a>
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}
