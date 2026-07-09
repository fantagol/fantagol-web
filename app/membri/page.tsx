"use client";

import { useEffect, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import KitPreview from "../../components/club/KitPreview";
import { supabase } from "../../lib/supabaseClient";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type Member = {
  id: string;
  clubName: string;
  realName: string | null;
  role: string;
  avatarUrl: string | null;
  kitTemplate: string;
  kitPrimaryColor: string;
  kitSecondaryColor: string;
  kitThirdColor: string;
  kitLogoMode: string;
  kitCrestPosition: string;
  starsCount: number;
};

const demoMembers: Member[] = [
  {
    id: "1",
    clubName: "Real Exact",
    realName: "Mario Rossi",
    role: "owner",
    avatarUrl: null,
    kitTemplate: "solid",
    kitPrimaryColor: "#FFFFFF",
    kitSecondaryColor: "#111417",
    kitThirdColor: "#A6E824",
    kitLogoMode: "center_horizontal",
    kitCrestPosition: "left_chest",
    starsCount: 2,
  },
  {
    id: "2",
    clubName: "FantaGol United",
    realName: "Luca Bianchi",
    role: "member",
    avatarUrl: null,
    kitTemplate: "vertical_3",
    kitPrimaryColor: "#A6E824",
    kitSecondaryColor: "#111417",
    kitThirdColor: "#FFFFFF",
    kitLogoMode: "center_horizontal",
    kitCrestPosition: "left_chest",
    starsCount: 1,
  },
  {
    id: "3",
    clubName: "Bonus Show",
    realName: "Andrea Verdi",
    role: "member",
    avatarUrl: null,
    kitTemplate: "diagonal",
    kitPrimaryColor: "#1f2427",
    kitSecondaryColor: "#A6E824",
    kitThirdColor: "#FFFFFF",
    kitLogoMode: "wordmark_only",
    kitCrestPosition: "left_chest",
    starsCount: 0,
  },
];

function roleLabel(role: string) {
  if (role === "owner") return "Admin";
  return "Membro";
}

function mapClubToMember(club: any, fallbackDisplayName: string, fallbackRole: string): Member {
  return {
    id: club.club_id || "me",
    clubName: club.name || fallbackDisplayName || "Club FantaGol",
    realName: club.real_name || null,
    role: fallbackRole || "member",
    avatarUrl: club.crest_url || null,
    kitTemplate: club.kit_template || "solid",
    kitPrimaryColor: club.kit_primary_color || "#FFFFFF",
    kitSecondaryColor: club.kit_secondary_color || "#A6E824",
    kitThirdColor: club.kit_third_color || "#FFFFFF",
    kitLogoMode: club.kit_logo_mode || "center_horizontal",
    kitCrestPosition: club.kit_crest_position || "left_chest",
    starsCount: club.stars_count || 0,
  };
}


export default function MembriPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [members, setMembers] = useState<Member[]>(demoMembers);

  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadMembers() {
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

      const { data: clubData } = await supabase.rpc("get_my_club_rpc");
      const currentClub = (clubData || [])[0];

      if (currentClub) {
        const realMember = mapClubToMember(
          currentClub,
          firstLeague?.display_name || "Club FantaGol",
          firstLeague?.role || "member"
        );

        setMembers([
          realMember,
          ...demoMembers.filter((member) => member.id !== realMember.id),
        ]);
      }

      /*
        Collegamento dati definitivo:
        qui useremo una RPC tipo get_current_league_members_rpc()
        che dovrà restituire tutti i membri reali della lega:
        - club name
        - real name
        - avatar
        - kit
        - role
      */
    }

    loadMembers();
  }, []);

  return (
    <main className="min-h-screen bg-black pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 w-full max-w-6xl items-center justify-between overflow-hidden px-4 md:px-6">
          <div className="pointer-events-none relative z-0 block min-w-0 -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6">
            <FantaGolLogo />
          </div>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu"
            className="shrink-0 rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
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

      <section className="mx-auto w-full max-w-6xl overflow-hidden px-4 py-10 sm:px-6">
        <p className="text-sm font-semibold uppercase tracking-[0.3em] text-[#A6E824]">
          Lega
        </p>

        <h1 className="mt-3 text-5xl font-black">Membri</h1>

        <p className="mt-4 max-w-2xl text-gray-400">
          Tutti i Club iscritti alla lega, con maglia, avatar, nome del Club e nome reale.
        </p>

        <div className="mt-8 grid min-w-0 gap-4 md:grid-cols-2">
          {members.map((member) => (
            <article
              key={member.id}
              className="min-w-0 overflow-hidden rounded-3xl border border-gray-700 bg-[#111111] p-4 transition hover:border-[#A6E824]/60 sm:p-5"
            >
              <div className="grid min-w-0 grid-cols-[64px_1fr] items-center gap-3 sm:grid-cols-[80px_1fr] sm:gap-4">
                <div className="flex h-24 w-16 shrink-0 items-center justify-center overflow-hidden rounded-2xl bg-[#171b1d] sm:h-28 sm:w-20">
                  <div className="scale-[0.38] sm:scale-[0.46]">
                    <KitPreview
                      primary={member.kitPrimaryColor}
                      secondary={member.kitSecondaryColor}
                      third={member.kitThirdColor}
                      template={member.kitTemplate}
                      logoMode={member.kitLogoMode}
                      crestPosition={member.kitCrestPosition}
                      starsCount={member.starsCount}
                    />
                  </div>
                </div>

                <div className="min-w-0 flex-1">
                  <div className="flex min-w-0 items-center gap-3">
                    <div className="flex h-12 w-12 shrink-0 items-center justify-center overflow-hidden rounded-full border-2 border-[#A6E824]/60 bg-black sm:h-14 sm:w-14">
                      {member.avatarUrl ? (
                        <img
                          src={member.avatarUrl}
                          alt={member.clubName}
                          className="h-full w-full object-cover"
                        />
                      ) : (
                        <span className="text-xl font-black text-[#A6E824]">
                          {member.clubName.slice(0, 1).toUpperCase()}
                        </span>
                      )}
                    </div>

                    <div className="min-w-0">
                      <h2 className="max-w-full truncate text-lg font-black sm:text-xl">
                        {member.clubName}
                      </h2>

                      <p className="mt-1 truncate text-sm font-semibold text-gray-400">
                        {member.realName || "Nome reale non inserito"}
                      </p>
                    </div>
                  </div>

                  <div className="mt-4 flex min-w-0 flex-wrap gap-2">
                    <span className="rounded-full border border-[#A6E824]/30 bg-[#A6E824]/10 px-3 py-1 text-xs font-black text-[#A6E824]">
                      {roleLabel(member.role)}
                    </span>

                    <span className="rounded-full border border-gray-700 bg-black px-3 py-1 text-xs font-black text-gray-400">
                      Stelle: {member.starsCount}
                    </span>
                  </div>
                </div>
              </div>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}

