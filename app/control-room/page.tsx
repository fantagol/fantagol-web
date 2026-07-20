"use client";

import { useEffect, useState } from "react";
import FantaGolLogo from "../../components/FantaGolLogo";
import HamburgerDrawer from "../../components/app/HamburgerDrawer";
import { supabase } from "../../lib/supabaseClient";

type LeagueInfo = {
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

function ControlRoomIcon() {
  return (
    <span className="flex h-16 w-16 shrink-0 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_28px_rgba(166,232,36,0.18)]">
      <span className="relative h-11 w-11 rounded-xl border border-[#A6E824]/70 bg-black/40">
        <span className="absolute left-2 top-2 h-2 w-2 rounded-full bg-[#A6E824]" />
        <span className="absolute right-2 top-2 h-2 w-2 rounded-full bg-[#A6E824]/45" />
        <span className="absolute bottom-2 left-2 right-2 flex items-end gap-1">
          <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50" />
          <span className="h-7 flex-1 rounded-t bg-[#A6E824]" />
          <span className="h-5 flex-1 rounded-t bg-[#A6E824]/70" />
        </span>
      </span>
    </span>
  );
}

function VideoIcon() {
  return (
    <span className="flex h-14 w-14 items-center justify-center rounded-2xl border border-white/10 bg-[#071015]">
      <span className="ml-1 h-0 w-0 border-y-[12px] border-l-[18px] border-y-transparent border-l-[#A6E824]" />
    </span>
  );
}

function PassIcon() {
  return (
    <span className="flex h-14 w-14 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_18px_rgba(166,232,36,0.16)]">
      <span className="relative h-8 w-10 rounded-xl border border-[#A6E824]/70 bg-black/40">
        <span className="absolute left-2 right-2 top-2 h-1 rounded-full bg-[#A6E824]" />
        <span className="absolute bottom-2 left-2 h-2 w-2 rounded-full bg-[#A6E824]/70" />
        <span className="absolute bottom-2 right-2 h-2 w-4 rounded-full bg-[#A6E824]/35" />
      </span>
    </span>
  );
}

function AccessIcon() {
  return (
    <span className="flex h-14 w-14 items-center justify-center rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 text-5xl font-black leading-none text-[#A6E824] shadow-[0_0_18px_rgba(166,232,36,0.16)]">
      ➜
    </span>
  );
}

function FeaturePill({ label }: { label: string }) {
  return (
    <span className="rounded-full border border-white/10 bg-black/30 px-3 py-2 text-xs font-black uppercase tracking-[0.12em] text-gray-300">
      {label}
    </span>
  );
}

export default function ControlRoomPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [availablePasses] = useState(0);
  const [passPopupOpen, setPassPopupOpen] = useState(false);
  const [leagueInfo, setLeagueInfo] = useState<LeagueInfo>({
    leagueName: "FantaGol",
    displayName: "Club FantaGol",
    inviteCode: "",
    role: "member",
  });

  useEffect(() => {
    async function loadLeagueInfo() {
      const {
        data: { session },
      } = await supabase.auth.getSession();

      if (!session?.user) {
        window.location.href = "/login";
        return;
      }

      const { data } = await supabase.rpc("get_my_leagues_rpc");
      const firstLeague = (data || [])[0];

      if (firstLeague) {
        setLeagueInfo({
          leagueName: firstLeague.league_name || "Lega FantaGol",
          displayName: firstLeague.display_name || "Club FantaGol",
          inviteCode: firstLeague.invite_code || firstLeague.league_id || "",
          role: firstLeague.role || "member",
        });
      }
    }

    loadLeagueInfo();
  }, []);

  return (
    <main className="min-h-screen overflow-x-hidden bg-[#061014] pt-14 text-white">
      <header className="fixed inset-x-0 top-0 z-[80] border-b border-[#A6E824]/25 bg-[#1f2427] shadow-2xl shadow-black/80">
        <div className="mx-auto flex h-14 w-full max-w-6xl items-center justify-between overflow-visible px-4 md:px-6">
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

      <section className="mx-auto w-full max-w-6xl px-4 pb-16 pt-8 sm:px-6 sm:pt-10">
        <section className="rounded-3xl border border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] p-6 shadow-2xl shadow-black/70 sm:p-8">
          <div className="flex flex-col gap-5 sm:flex-row sm:items-center">
            <ControlRoomIcon />

            <div className="min-w-0">
              <p className="text-sm font-black uppercase tracking-[0.3em] text-[#A6E824]">
                FantaGol
              </p>

              <h1 className="mt-2 text-5xl font-black tracking-tight sm:text-6xl">
                Control Room
              </h1>

              <p className="mt-4 max-w-3xl text-base leading-7 text-gray-300 sm:text-lg sm:leading-8">
                La Control Room è l&apos;area avanzata dedicata alle statistiche globali FantaGol:
                dati aggregati e anonimi sulle giocate degli utenti, trend dei pronostici,
                squadre più lette, risultati più cercati, bonus, malus e andamento generale
                delle scelte della community.
              </p>
            </div>
          </div>

          <div className="mt-7 flex flex-wrap gap-2">
            <FeaturePill label="Dati aggregati" />
            <FeaturePill label="Utenti anonimi" />
            <FeaturePill label="Trend pronostici" />
            <FeaturePill label="Squadre" />
            <FeaturePill label="Bonus e malus" />
          </div>
        </section>

        <section className="mt-6 rounded-3xl border border-white/10 bg-[#0b1419] p-5 shadow-xl shadow-black/30 sm:p-6">
          <h2 className="text-2xl font-black text-[#A6E824]">
            Cosa contiene
          </h2>

          <p className="mt-3 max-w-4xl text-sm leading-7 text-gray-300 sm:text-base">
            Le informazioni vengono elaborate in forma aggregata e anonima. Non vengono mostrati
            dati personali dei singoli utenti: la Control Room serve a leggere il comportamento
            generale del gioco FantaGol, confrontando volume delle giocate, distribuzione dei
            pronostici, precisione sulle squadre, frequenza degli exact e incidenza dei bonus/malus.
          </p>

          <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
              <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                Pronostici
              </p>
              <p className="mt-2 text-xl font-black text-white">
                Trend 1-X-2
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
              <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                Squadre
              </p>
              <p className="mt-2 text-xl font-black text-white">
                Letture globali
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
              <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                Risultati
              </p>
              <p className="mt-2 text-xl font-black text-white">
                Exact più scelti
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
              <p className="text-[10px] font-black uppercase tracking-[0.16em] text-gray-500">
                Bonus/Malus
              </p>
              <p className="mt-2 text-xl font-black text-white">
                Incidenza live
              </p>
            </div>
          </div>
        </section>

        <section className="mt-6 grid grid-cols-2 gap-3 sm:gap-4">
          <button
            type="button"
            onClick={() => {
              if (availablePasses <= 0) {
                setPassPopupOpen(true);
                return;
              }

              window.location.href = `/control-room/session-${Date.now()}`;
            }}
            className="rounded-3xl border border-[#A6E824]/40 bg-[#A6E824]/10 p-4 text-left shadow-[0_0_22px_rgba(166,232,36,0.10)] transition hover:-translate-y-0.5 hover:border-[#A6E824] hover:brightness-110 sm:p-5"
          >
            <AccessIcon />

            <h3 className="mt-4 text-xl font-black uppercase tracking-[0.08em] text-[#A6E824] sm:text-2xl">
              Accedi
            </h3>
          </button>

          <div className="rounded-3xl border border-white/10 bg-[#111417] p-4 text-left shadow-lg shadow-black/30 sm:p-5">
            <p className="text-[10px] font-black uppercase tracking-[0.18em] text-gray-500">
              Pass disponibili
            </p>

            <div className={`mt-3 text-6xl font-black leading-none ${availablePasses > 0 ? "text-[#A6E824]" : "text-gray-500"}`}>
              {availablePasses}
            </div>
          </div>
        </section>

        <section className="mt-6 grid gap-4 md:grid-cols-2">
          <button
            type="button"
            className="rounded-3xl border border-white/10 bg-[#111417] p-6 text-left shadow-lg shadow-black/30 transition hover:-translate-y-0.5 hover:border-[#A6E824]/70 hover:brightness-110"
          >
            <VideoIcon />

            <h3 className="mt-5 text-2xl font-black">
              Guarda un video
            </h3>
          </button>

          <button
            type="button"
            className="rounded-3xl border border-[#A6E824]/40 bg-[#A6E824]/10 p-6 text-left shadow-[0_0_28px_rgba(166,232,36,0.12)] transition hover:-translate-y-0.5 hover:border-[#A6E824] hover:brightness-110"
          >
            <PassIcon />

            <h3 className="mt-5 text-2xl font-black text-[#A6E824]">
              Acquista Pass Control Room
            </h3>
          </button>
        </section>
      </section>
      {passPopupOpen && (
        <div
          className="fixed inset-0 z-[400] flex items-center justify-center bg-black/75 px-4 text-white"
          onClick={() => setPassPopupOpen(false)}
        >
          <div
            className="w-full max-w-md rounded-3xl border border-[#A6E824]/35 bg-[#0b1419] p-6 shadow-2xl shadow-black/80"
            onClick={(event) => event.stopPropagation()}
          >
            <p className="text-sm font-black uppercase tracking-[0.25em] text-[#A6E824]">
              Control Room
            </p>

            <h2 className="mt-3 text-3xl font-black">
              Pass non disponibili
            </h2>

            <p className="mt-4 text-sm leading-6 text-gray-300">
              Per accedere puoi guardare un video oppure acquistare un Pass Control Room.
            </p>

            <div className="mt-6 grid gap-3">
              <button
                type="button"
                onClick={() => setPassPopupOpen(false)}
                className="rounded-2xl border border-white/10 bg-black/30 px-5 py-4 text-left font-black transition hover:border-[#A6E824]/60"
              >
                Guarda un video
              </button>

              <button
                type="button"
                onClick={() => setPassPopupOpen(false)}
                className="rounded-2xl border border-[#A6E824]/35 bg-[#A6E824]/10 px-5 py-4 text-left font-black text-[#A6E824] transition hover:border-[#A6E824]"
              >
                Acquista Pass Control Room
              </button>

              <button
                type="button"
                onClick={() => setPassPopupOpen(false)}
                className="rounded-2xl border border-gray-700 px-5 py-3 text-center text-sm font-black text-gray-400 transition hover:border-white/20 hover:text-white"
              >
                Chiudi
              </button>
            </div>
          </div>
        </div>
      )}

    </main>
  );
}

