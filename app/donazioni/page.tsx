"use client";

import { useEffect, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

const LAST_LEAGUE_STORAGE_KEY = "fantagol:last-league-id";

type LeagueInfo = {
  leagueId: string;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
};

type ContributionOption = {
  amount: string;
  title: string;
  description: string;
  buttonLabel: string;
};

const CONTRIBUTION_OPTIONS: ContributionOption[] = [
  {
    amount: "€2",
    title: "Un piccolo sostegno",
    description: "Un semplice contributo per supportare FantaGol.",
    buttonLabel: "Sostieni con €2",
  },
  {
    amount: "€5",
    title: "Sostieni FantaGol",
    description: "Un contributo per aiutare lo sviluppo del progetto.",
    buttonLabel: "Sostieni con €5",
  },
  {
    amount: "€10",
    title: "Grande sostenitore",
    description: "Un aiuto per accompagnare la crescita della piattaforma.",
    buttonLabel: "Sostieni con €10",
  },
  {
    amount: "Importo libero",
    title: "Scegli tu",
    description: "Decidi liberamente quanto desideri contribuire.",
    buttonLabel: "Scegli l'importo",
  },
];

export default function DonazioniPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [noticeOpen, setNoticeOpen] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueId: "",
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadPageContext() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");

      if (!error) {
        const leagues = (data || []) as MyLeagueRpcRow[];
        const rememberedLeagueId =
          window.localStorage.getItem(LAST_LEAGUE_STORAGE_KEY) || "";

        const selectedLeague =
          leagues.find((league) => league.league_id === rememberedLeagueId) ||
          leagues[0];

        if (selectedLeague?.league_id) {
          window.localStorage.setItem(
            LAST_LEAGUE_STORAGE_KEY,
            selectedLeague.league_id,
          );

          setLeagueInfo({
            leagueId: selectedLeague.league_id,
            leagueName: selectedLeague.league_name || "Lega FantaGol",
            displayName: selectedLeague.display_name || "Club FantaGol",
            inviteCode:
              selectedLeague.invite_code || selectedLeague.league_id || "",
            role: selectedLeague.role || "member",
          });
        }
      }

      setLoading(false);
    }

    void loadPageContext();
  }, []);

  function openContributionNotice() {
    setNoticeOpen(true);
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

      <section className="mx-auto w-full max-w-6xl px-4 py-10 sm:px-6">
        <p className="text-sm font-semibold uppercase tracking-[0.3em] text-[#A6E824]">
          Community
        </p>

        <h1 className="mt-3 text-4xl font-black sm:text-5xl">
          Sostieni FantaGol
        </h1>

        <div className="mt-8 rounded-3xl border border-[#A6E824]/25 bg-gradient-to-br from-[#20282b] via-[#121719] to-[#080909] p-6 shadow-2xl shadow-black/70 sm:p-8">
          <h2 className="max-w-3xl text-2xl font-black leading-tight text-white sm:text-3xl">
            FantaGol nasce come applicazione gratuita e sempre lo sarà.
          </h2>

          <p className="mt-5 max-w-3xl text-base leading-7 text-gray-300">
            Aiutaci a sostenere i costi di gestione, sviluppo e miglioramento
            della piattaforma.
          </p>

          <p className="mt-3 max-w-3xl text-base leading-7 text-gray-400">
            Ogni contributo è volontario e ci permette di continuare a far
            crescere FantaGol mantenendolo accessibile a tutti.
          </p>
        </div>

        <div className="mt-10">
          <h2 className="text-2xl font-black text-white">
            Scegli il tuo contributo
          </h2>

          <div className="mt-5 grid gap-4 md:grid-cols-2">
            {CONTRIBUTION_OPTIONS.map((option) => (
              <article
                key={option.amount}
                className="flex min-h-[230px] flex-col rounded-3xl border border-white/10 bg-[#111417] p-6 shadow-xl shadow-black/40 transition hover:border-[#A6E824]/45"
              >
                <p className="text-3xl font-black text-[#A6E824]">
                  {option.amount}
                </p>

                <h3 className="mt-4 text-xl font-black text-white">
                  {option.title}
                </h3>

                <p className="mt-3 flex-1 text-sm leading-6 text-gray-400">
                  {option.description}
                </p>

                <button
                  type="button"
                  onClick={openContributionNotice}
                  className="mt-6 w-full rounded-2xl bg-[#A6E824] px-5 py-3 text-sm font-black text-black transition hover:brightness-110 active:scale-[0.99]"
                >
                  {option.buttonLabel}
                </button>
              </article>
            ))}
          </div>
        </div>

        <div className="mt-8 rounded-3xl border border-white/10 bg-[#111417] p-6 sm:p-7">
          <p className="text-sm leading-6 text-gray-300">
            Il contributo è volontario, una tantum e non offre alcun vantaggio
            nelle classifiche o nelle competizioni.
          </p>

          <p className="mt-4 text-sm leading-6 text-gray-400">
            I pagamenti saranno gestiti in modo sicuro tramite Stripe. FantaGol
            non conserva i dati della tua carta.
          </p>
        </div>

        <p className="pb-4 pt-9 text-center text-base font-black text-[#A6E824]">
          Grazie per contribuire alla crescita di FantaGol.
        </p>

        {loading && (
          <p className="text-center text-xs font-semibold text-gray-600">
            Sincronizzazione account...
          </p>
        )}
      </section>

      {noticeOpen && (
        <div
          className="fixed inset-0 z-[400] flex items-center justify-center bg-black/80 px-4"
          onClick={() => setNoticeOpen(false)}
        >
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="contribution-notice-title"
            className="w-full max-w-md rounded-3xl border border-[#A6E824]/35 bg-[#111417] p-6 shadow-2xl shadow-black/80"
            onClick={(event) => event.stopPropagation()}
          >
            <p className="text-xs font-black uppercase tracking-[0.25em] text-[#A6E824]">
              Sostieni FantaGol
            </p>

            <h2
              id="contribution-notice-title"
              className="mt-3 text-2xl font-black text-white"
            >
              Contributi disponibili prossimamente
            </h2>

            <p className="mt-4 text-sm leading-6 text-gray-300">
              Il collegamento sicuro con Stripe sarà attivato prima
              dell'apertura ufficiale dei contributi.
            </p>

            <button
              type="button"
              onClick={() => setNoticeOpen(false)}
              className="mt-6 w-full rounded-2xl bg-[#A6E824] px-5 py-3 text-sm font-black text-black transition hover:brightness-110"
            >
              Ho capito
            </button>
          </div>
        </div>
      )}
    </main>
  );
}
