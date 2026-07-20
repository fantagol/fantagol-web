"use client";

/* eslint-disable @next/next/no-img-element -- Dynamic external assets intentionally preserve the current crop, fallback, and sizing contracts. */
import { useCallback, useEffect, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import KitPreview from "../../components/club/KitPreview";
import { supabase } from "../../lib/supabaseClient";

type LeagueInfo = {
  leagueId: string;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type Member = {
  id: string;
  userId: string | null;
  clubName: string;
  realName: string | null;
  role: string;
  status: string;
  avatarUrl: string | null;
  kitTemplate: string;
  kitPrimaryColor: string;
  kitSecondaryColor: string;
  kitThirdColor: string;
  kitLogoMode: string;
  kitCrestPosition: string;
  starsCount: number;
};

type LeagueMembershipRow = {
  membership_id: string;
  league_id: string;
  user_id: string | null;
  display_name: string;
  role: string;
  status: string;
  joined_at: string;
  club_id: string | null;
  club_name: string | null;
  real_name: string | null;
  crest_url: string | null;
  kit_template: string | null;
  kit_primary_color: string | null;
  kit_secondary_color: string | null;
  kit_third_color: string | null;
  kit_logo_mode: string | null;
  kit_crest_position: string | null;
  stars_count: number | null;
};

function roleLabel(role: string) {
  if (role === "admin") return "Admin";
  if (role === "vice") return "Vice";
  return "Membro";
}

function mapMembershipToMember(row: LeagueMembershipRow): Member {
  return {
    id: row.membership_id,
    userId: row.user_id,
    clubName:
      !row.club_name || row.club_name === "FantaGol Club"
        ? row.display_name || "Club FantaGol"
        : row.club_name,
    realName: row.real_name || null,
    role: row.role || "member",
    status: row.status || "active",
    avatarUrl: row.crest_url || null,
    kitTemplate: row.kit_template || "solid",
    kitPrimaryColor: row.kit_primary_color || "#FFFFFF",
    kitSecondaryColor: row.kit_secondary_color || "#A6E824",
    kitThirdColor: row.kit_third_color || "#FFFFFF",
    kitLogoMode: row.kit_logo_mode || "center_horizontal",
    kitCrestPosition: row.kit_crest_position || "left_chest",
    starsCount: row.stars_count || 0,
  };
}

export default function MembriPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [members, setMembers] = useState<Member[]>([]);
  const [currentUserId, setCurrentUserId] = useState("");
  const [loading, setLoading] = useState(true);
  const [actionMemberId, setActionMemberId] = useState("");
  const [errorMessage, setErrorMessage] = useState("");

  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueId: "",
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  const loadMembers = useCallback(async () => {
    setLoading(true);
    setErrorMessage("");

    const {
      data: { session },
    } = await supabase.auth.getSession();

    if (!session?.user) {
      window.location.href = "/login";
      return;
    }

    setCurrentUserId(session.user.id);

    const { data: leaguesData, error: leaguesError } = await supabase.rpc(
      "get_my_leagues_rpc"
    );

    if (leaguesError) {
      setErrorMessage(leaguesError.message);
      setLoading(false);
      return;
    }

    const firstLeague = (leaguesData || [])[0];

    if (!firstLeague) {
      setErrorMessage("Nessuna lega attiva trovata.");
      setLoading(false);
      return;
    }

    setLeagueInfo({
      leagueId: firstLeague.league_id || "",
      leagueName: firstLeague.league_name || "Lega FantaGol",
      displayName: firstLeague.display_name || "Club FantaGol",
      inviteCode: firstLeague.invite_code || firstLeague.league_id || "",
      role: firstLeague.role || "member",
    });

    const { data: membersData, error: membersError } = await supabase.rpc(
      "get_current_league_members_rpc",
      {
        target_league_id: firstLeague.league_id,
      }
    );

    if (membersError) {
      setErrorMessage(membersError.message);
      setLoading(false);
      return;
    }

    setMembers(
      ((membersData || []) as LeagueMembershipRow[]).map(
        mapMembershipToMember
      )
    );
    setLoading(false);
  }, []);

  useEffect(() => {
    // Initial client-side synchronization with league membership data.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadMembers();
  }, [loadMembers]);

  async function handleAssignVice(memberId: string) {
    if (!leagueInfo.leagueId) return;

    setActionMemberId(memberId);
    setErrorMessage("");

    const { error } = await supabase.rpc("assign_league_vice_rpc", {
      target_league_id: leagueInfo.leagueId,
      target_member_id: memberId,
    });

    if (error) {
      setErrorMessage(error.message);
      setActionMemberId("");
      return;
    }

    await loadMembers();
    setActionMemberId("");
  }

  async function handleRevokeVice(memberId: string) {
    if (!leagueInfo.leagueId) return;

    setActionMemberId(memberId);
    setErrorMessage("");

    const { error } = await supabase.rpc("revoke_league_vice_rpc", {
      target_league_id: leagueInfo.leagueId,
    });

    if (error) {
      setErrorMessage(error.message);
      setActionMemberId("");
      return;
    }

    await loadMembers();
    setActionMemberId("");
  }

  const isAdmin =
    leagueInfo.role === "admin" &&
    members.some(
      (member) =>
        member.userId === currentUserId &&
        member.role === "admin" &&
        member.status === "active"
    );

  const activeVice = members.find(
    (member) => member.role === "vice" && member.status === "active"
  );

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
          Tutti i Club iscritti alla lega, con maglia, avatar, nome del Club e
          nome reale.
        </p>

        {isAdmin && !loading && !errorMessage && (
          <div className="mt-6 rounded-2xl border border-[#A6E824]/25 bg-[#A6E824]/5 px-4 py-3 text-sm text-gray-300">
            {activeVice
              ? `Vice attuale: ${activeVice.clubName}`
              : "Nessun vice nominato. Prima del lock del roster sarà necessario nominarne uno."}
          </div>
        )}

        {loading && (
          <div className="mt-8 rounded-3xl border border-gray-700 bg-[#111111] p-6 text-gray-400">
            Caricamento membri...
          </div>
        )}

        {!loading && errorMessage && (
          <div className="mt-8 rounded-3xl border border-red-500/40 bg-red-950/20 p-6 text-red-300">
            {errorMessage}
          </div>
        )}

        {!loading && !errorMessage && members.length === 0 && (
          <div className="mt-8 rounded-3xl border border-gray-700 bg-[#111111] p-6 text-gray-400">
            Nessun membro disponibile.
          </div>
        )}

        {!loading && !errorMessage && members.length > 0 && (
          <div className="mt-8 grid min-w-0 gap-4 md:grid-cols-2">
            {members.map((member) => {
              const actionLoading = actionMemberId === member.id;
              const canAssignVice =
                isAdmin &&
                member.status === "active" &&
                member.role === "member" &&
                !activeVice;
              const canRevokeVice =
                isAdmin &&
                member.status === "active" &&
                member.role === "vice";

              return (
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

                        {member.status !== "active" && (
                          <span className="rounded-full border border-amber-500/30 bg-amber-500/10 px-3 py-1 text-xs font-black text-amber-300">
                            {member.status}
                          </span>
                        )}
                      </div>

                      {(canAssignVice || canRevokeVice) && (
                        <button
                          type="button"
                          disabled={actionLoading}
                          onClick={() =>
                            canRevokeVice
                              ? handleRevokeVice(member.id)
                              : handleAssignVice(member.id)
                          }
                          className="mt-4 w-full rounded-xl border border-[#A6E824]/50 px-4 py-2 text-sm font-black text-[#A6E824] transition hover:bg-[#A6E824]/10 disabled:cursor-not-allowed disabled:opacity-50"
                        >
                          {actionLoading
                            ? "Aggiornamento..."
                            : canRevokeVice
                              ? "Revoca Vice"
                              : "Nomina Vice"}
                        </button>
                      )}
                    </div>
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </section>
    </main>
  );
}
