"use client";

import { useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

type LeagueShellInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  membership_id?: string | null;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
  status?: string | null;
};

export default function LegheLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const [menuOpen, setMenuOpen] = useState(false);
  const [hasUnseenRewards, setHasUnseenRewards] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueShellInfo>({
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadLeagueInfo() {
      const match = pathname.match(/\/leghe\/([^\/]+)/);
      const leagueId = match?.[1];

      if (!leagueId || leagueId === "fantagol-serie-a") return;

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const current = (data || []).find((row: MyLeagueRpcRow) => row.league_id === leagueId);
      if (!current) return;

      setLeagueInfo({
        leagueName: current.league_name || "Lega FantaGol",
        displayName: current.display_name || "Club FantaGol",
        inviteCode: current.invite_code || leagueId,
        role: current.role || "member",
      });
    }

    loadLeagueInfo();
  }, [pathname]);

  useEffect(() => {
    let cancelled = false;

    async function loadRewardSignal() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (cancelled) return;

      if (!session?.user) {
        setHasUnseenRewards(false);
        return;
      }

      const { data, error } = await supabase.rpc(
        "get_my_reward_signal_rpc",
      );

      if (error || cancelled) return;

      const payload =
        data && typeof data === "object" && !Array.isArray(data)
          ? (data as Record<string, unknown>)
          : null;

      setHasUnseenRewards(payload?.show_badge === true);
    }

    void loadRewardSignal();

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, session) => {
      if (cancelled) return;

      if (!session?.user) {
        setHasUnseenRewards(false);
        return;
      }

      if (
        event === "INITIAL_SESSION" ||
        event === "SIGNED_IN" ||
        event === "TOKEN_REFRESHED"
      ) {
        void loadRewardSignal();
      }
    });

    const handleWindowFocus = () => {
      void loadRewardSignal();
    };

    window.addEventListener("focus", handleWindowFocus);

    return () => {
      cancelled = true;
      subscription.unsubscribe();
      window.removeEventListener("focus", handleWindowFocus);
    };
  }, [pathname]);

  return (
    <>
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 md:px-6">
          <a
                        className="pointer-events-none relative z-0 block -translate-x-8 translate-y-5 md:-translate-x-20 md:translate-y-6"
          >
            <FantaGolLogo />
          </a>

          <button
            type="button"
            onClick={() => setMenuOpen(true)}
            aria-label="Apri menu lega"
            className="relative rounded-lg border border-gray-600 bg-[#2b2f31] px-3 py-2 text-2xl leading-none text-white transition hover:border-[#A6E824]"
          >
            ☰
            {hasUnseenRewards && (
              <span
                aria-hidden="true"
                className="absolute -right-1 -top-1 h-2.5 w-2.5 rounded-full border border-[#071015] bg-[#A6E824] shadow-[0_0_8px_rgba(166,232,36,0.85)]"
              />
            )}
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

      <div className="pt-14">
        {children}
      </div>
    </>
  );
}

