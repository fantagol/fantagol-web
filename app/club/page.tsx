"use client";

import { useEffect, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import KitPreview from "../../components/club/KitPreview";
import { supabase } from "../../lib/supabaseClient";

type Club = {
  club_id: string;
  name: string;
  motto: string | null;
  crest_url: string | null;
  kit_template: string;
  kit_primary_color: string;
  kit_secondary_color: string;
  kit_third_color: string;
  kit_logo_mode: string;
  kit_crest_position: string;
  stars_count: number;
  total_titles: number;
  fantacalcio_titles?: number;
  one_to_one_titles?: number;
  punti_puri_titles?: number;
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

      const { data: leaguesData } = await supabase.rpc("get_my_leagues_rpc");
      const firstLeague = (leaguesData || [])[0];

      if (firstLeague) {
        setLeagueInfo({
          leagueName: firstLeague.league_name || "Lega FantaGol",
          displayName: firstLeague.display_name || "Club FantaGol",
          inviteCode: firstLeague.invite_code || firstLeague.league_id || "",
          role: firstLeague.role || "member",
        });
      }

      const { data, error } = await supabase.rpc("get_my_club_rpc");

      if (error) {
        alert(error.message);
        setLoading(false);
        return;
      }

      if (data && data.length > 0) {
        setClub(data[0]);
      }

      setLoading(false);
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
      window.history.replaceState({}, "", "/club");
    }, 250);

    return () => window.clearTimeout(timer);
  }, [loading]);

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

        <h1 className="mt-3 text-5xl font-black">{club.name}</h1>

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
                    <div className="flex items-center gap-2"><span className="flex h-8 w-8 items-center justify-center rounded-lg border border-[#A6E824]/30 bg-[#A6E824]/10 text-[#A6E824]">🏆</span><div className="font-black">Fantacalcio</div></div>
                    
                  </div>
                  <div className="text-2xl font-black text-[#A6E824]">
                    {club.fantacalcio_titles || 0}
                  </div>
                </div>

                <div className="flex items-center justify-between rounded-2xl border border-gray-800 bg-black px-5 py-4">
                  <div>
                    <div className="flex items-center gap-2"><span className="flex h-8 w-8 items-center justify-center rounded-lg border border-cyan-400/30 bg-cyan-500/10 text-cyan-300">⚔️</span><div className="font-black">One to One</div></div>
                    
                  </div>
                  <div className="text-2xl font-black text-[#A6E824]">
                    {club.one_to_one_titles || 0}
                  </div>
                </div>

                <div className="flex items-center justify-between rounded-2xl border border-gray-800 bg-black px-5 py-4">
                  <div>
                    <div className="flex items-center gap-2"><span className="flex h-8 w-8 items-center justify-center rounded-lg border border-violet-400/30 bg-violet-500/10 text-violet-300">⭐</span><div className="font-black">Punti Puri</div></div>
                    
                  </div>
                  <div className="text-2xl font-black text-[#A6E824]">
                    {club.punti_puri_titles || 0}
                  </div>
                </div>
              </div>

              
            </div>

            <div className="rounded-3xl border border-gray-700 bg-[#111111] p-6">
             

              <div className="mt-6 space-y-4">
                <a
                  href="/club/kit"
                  className="block w-full rounded-2xl bg-[#A6E824] py-4 text-center font-bold text-black transition hover:brightness-110"
                >
                  Personalizza Kit
                </a>

                <a
                  href="/club/profilo"
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
