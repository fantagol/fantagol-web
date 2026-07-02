"use client";

import { useMemo, useState } from "react";
import { useParams } from "next/navigation";
import Badge from "../../../../components/ui/Badge";
import BottomNav from "../../../../components/app/BottomNav";
import LeagueTopBar from "../../../../components/app/LeagueTopBar";

type RoundPhase = "open" | "submitted" | "live" | "finished";

type Prediction = {
  home: string;
  away: string;
};

type Match = {
  home: string;
  away: string;
  kickoff: string;
  homeBadge: string;
  awayBadge: string;
  liveScore?: string;
  minute?: string;
};

const matches: Match[] = [
  { home: "Atalanta", away: "Sassuolo", kickoff: "Dom 23 Ago · 13:45", homeBadge: "ATA", awayBadge: "SAS", liveScore: "1 - 0", minute: "62'" },
  { home: "Bologna", away: "Lazio", kickoff: "Dom 23 Ago · 13:45", homeBadge: "BOL", awayBadge: "LAZ", liveScore: "0 - 0", minute: "HT" },
  { home: "Frosinone", away: "Juventus", kickoff: "Dom 23 Ago · 13:45", homeBadge: "FRO", awayBadge: "JUV", liveScore: "1 - 2", minute: "77'" },
  { home: "Genoa", away: "Napoli", kickoff: "Dom 23 Ago · 15:00", homeBadge: "GEN", awayBadge: "NAP", liveScore: "0 - 1", minute: "35'" },
  { home: "Inter", away: "Monza", kickoff: "Dom 23 Ago · 15:00", homeBadge: "INT", awayBadge: "MON", liveScore: "2 - 0", minute: "68'" },
  { home: "Parma", away: "Cagliari", kickoff: "Dom 23 Ago · 18:00", homeBadge: "PAR", awayBadge: "CAG" },
  { home: "Roma", away: "Fiorentina", kickoff: "Dom 23 Ago · 18:00", homeBadge: "ROM", awayBadge: "FIO" },
  { home: "Torino", away: "Milan", kickoff: "Dom 23 Ago · 20:45", homeBadge: "TOR", awayBadge: "MIL" },
  { home: "Udinese", away: "Como", kickoff: "Dom 23 Ago · 20:45", homeBadge: "UDI", awayBadge: "COM" },
  { home: "Pisa", away: "Cremonese", kickoff: "Lun 24 Ago · 20:45", homeBadge: "PIS", awayBadge: "CRE" },
];

const bonusMalus = [
  { key: "exact", icon: "◎", label: "Exact" },
  { key: "sign", icon: "✓", label: "Segno" },
  { key: "uo", icon: "%", label: "U/O" },
  { key: "gg", icon: "▣", label: "G/NG" },
  { key: "surprise", icon: "☆", label: "Sorpresa" },
  { key: "show", icon: "✴", label: "Show" },
  { key: "slam", icon: "◇", label: "Slam" },
  { key: "bad", icon: "×", label: "Cantonata" },
  { key: "opposite", icon: "↔", label: "Opposto" },
];

function clampGoals(value: string) {
  if (!/^\d*$/.test(value)) return null;
  return value.slice(0, 2);
}

function MatchBadge({ label }: { label: string }) {
  return (
    <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full border border-white/10 bg-black text-[10px] font-black text-white shadow-inner shadow-white/5">
      {label}
    </div>
  );
}

function BonusDots({ active = false }: { active?: boolean }) {
  return (
    <div className="mt-3 flex flex-wrap justify-center gap-1.5">
      {bonusMalus.map((item, index) => {
        const isActive = active && index < 3;
        const isMalus = item.key === "bad" || item.key === "opposite";

        return (
          <span
            key={item.key}
            title={item.label}
            className={`flex h-7 w-7 items-center justify-center rounded-full border text-xs font-black transition ${
              isActive
                ? isMalus
                  ? "border-red-500/70 bg-red-500/10 text-red-400 shadow-[0_0_12px_rgba(239,68,68,0.25)]"
                  : "border-[#A6E824]/70 bg-[#A6E824]/10 text-[#A6E824] shadow-[0_0_12px_rgba(166,232,36,0.28)]"
                : "border-white/10 bg-black text-gray-600"
            }`}
          >
            {item.icon}
          </span>
        );
      })}
    </div>
  );
}

export default function GiornataPage() {
  const params = useParams();
  const leagueId = params.id as string;

  const [menuOpen, setMenuOpen] = useState(false);
  const [phase, setPhase] = useState<RoundPhase>("open");
  const [predictions, setPredictions] = useState<Prediction[]>(
    matches.map(() => ({ home: "", away: "" }))
  );

  const complete = useMemo(
    () => predictions.every((prediction) => prediction.home !== "" && prediction.away !== ""),
    [predictions]
  );

  const submitted = phase !== "open";
  const live = phase === "live";
  const finished = phase === "finished";

  function updatePrediction(index: number, field: keyof Prediction, value: string) {
    if (submitted) return;

    const cleanValue = clampGoals(value);
    if (cleanValue === null) return;

    setPredictions((current) =>
      current.map((prediction, currentIndex) =>
        currentIndex === index ? { ...prediction, [field]: cleanValue } : prediction
      )
    );
  }

  function submitPredictions() {
    if (!complete) {
      alert("Completa tutti i pronostici prima di inviare.");
      return;
    }

    setPhase("submitted");
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function editPredictions() {
    setPhase("open");
  }

  return (
    <main className="min-h-screen bg-[#071015] pb-28 text-white">
      <LeagueTopBar
        leagueName="Amici del Bar"
        seasonName="Serie A 2026/27"
        onMenuClick={() => setMenuOpen(true)}
      />

      <section className="mx-auto max-w-5xl px-3 py-4">
        <div className="rounded-[1.7rem] border border-white/10 bg-[#0d171d] p-3 shadow-2xl shadow-black/40">
          <div className="flex items-center justify-between gap-3">
            <button className="flex h-11 w-11 items-center justify-center rounded-2xl border border-white/10 bg-black text-2xl text-gray-300">
              ‹
            </button>

            <div className="text-center">
              <p className="text-[11px] font-bold uppercase tracking-[0.35em] text-[#A6E824]">
                Serie A
              </p>
              <h1 className="mt-1 text-2xl font-black">Giornata 1</h1>
            </div>

            <button className="flex h-11 w-11 items-center justify-center rounded-2xl border border-white/10 bg-black text-2xl text-gray-300">
              ›
            </button>
          </div>
        </div>

        <div className="mt-4 rounded-[1.7rem] border border-[#A6E824]/20 bg-gradient-to-br from-[#17242b] via-[#101820] to-[#071015] p-4 shadow-2xl shadow-black/50">
          <div className="flex items-start justify-between gap-4">
            <div>
              <Badge variant={finished ? "success" : live ? "live" : submitted ? "success" : "default"}>
                {finished
                  ? "Giornata conclusa"
                  : live
                  ? "Giornata in corso"
                  : submitted
                  ? "Pronostici inviati"
                  : "Pronostici aperti"}
              </Badge>

              <h2 className="mt-3 text-3xl font-black leading-tight">
                {finished
                  ? "Punteggio finale"
                  : live
                  ? "Punti attuali"
                  : submitted
                  ? "Puoi ancora modificarli"
                  : "Inserisci pronostici"}
              </h2>

              <p className="mt-2 text-sm text-gray-400">
                {finished
                  ? "Tutti gli incontri sono terminati. Il punteggio è definitivo."
                  : live
                  ? "Il totale si aggiorna man mano che terminano gli incontri."
                  : submitted
                  ? "Ultimo invio salvato. Puoi modificarlo fino al primo fischio d'inizio."
                  : "Compila le 10 partite. L'ultimo invio sostituisce i precedenti."}
              </p>
            </div>

            <div className="text-right">
              <p className="text-xs font-bold uppercase tracking-[0.2em] text-gray-500">
                Punti
              </p>
              <p className={`mt-1 text-5xl font-black ${live ? "animate-pulse text-[#A6E824]" : "text-[#A6E824]"}`}>
                {finished ? "57" : live ? "38" : submitted ? "0" : "—"}
              </p>
              <p className="text-sm font-bold text-gray-500">pt</p>
            </div>
          </div>

          {submitted && !live && !finished && (
            <div className="mt-4 rounded-2xl border border-yellow-500/30 bg-yellow-500/10 p-3 text-sm text-yellow-100">
              Modalità Mobile: puoi scegliere gli abbinamenti. Se non lo fai, useremo automaticamente quelli fissi.
            </div>
          )}
        </div>

        <div className="mt-4 flex gap-2 overflow-x-auto pb-1">
          <button
            onClick={() => setPhase("open")}
            className={`rounded-full border px-4 py-2 text-xs font-black uppercase tracking-[0.12em] ${phase === "open" ? "border-[#A6E824] bg-[#A6E824] text-black" : "border-white/10 bg-[#0d171d] text-gray-400"}`}
          >
            Aperta
          </button>
          <button
            onClick={() => complete && setPhase("submitted")}
            className={`rounded-full border px-4 py-2 text-xs font-black uppercase tracking-[0.12em] ${phase === "submitted" ? "border-[#A6E824] bg-[#A6E824] text-black" : "border-white/10 bg-[#0d171d] text-gray-400"}`}
          >
            Inviata
          </button>
          <button
            onClick={() => complete && setPhase("live")}
            className={`rounded-full border px-4 py-2 text-xs font-black uppercase tracking-[0.12em] ${phase === "live" ? "border-[#A6E824] bg-[#A6E824] text-black" : "border-white/10 bg-[#0d171d] text-gray-400"}`}
          >
            Live mock
          </button>
          <button
            onClick={() => complete && setPhase("finished")}
            className={`rounded-full border px-4 py-2 text-xs font-black uppercase tracking-[0.12em] ${phase === "finished" ? "border-[#A6E824] bg-[#A6E824] text-black" : "border-white/10 bg-[#0d171d] text-gray-400"}`}
          >
            Finale mock
          </button>
        </div>

        <div className="mt-4 overflow-hidden rounded-[1.7rem] border border-white/10 bg-[#101820] shadow-2xl shadow-black/40">
          {matches.map((match, index) => {
            const prediction = predictions[index];
            const matchIsLive = live && index < 5;
            const matchIsFinished = finished || (live && index < 3);

            return (
              <div
                key={`${match.home}-${match.away}`}
                className={`border-b border-white/10 p-3 last:border-b-0 transition ${matchIsFinished ? "bg-black/15" : "bg-transparent"}`}
              >
                <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-3">
                  <div className="flex min-w-0 items-center gap-2">
                    <MatchBadge label={match.homeBadge} />
                    <div className="min-w-0">
                      <p className="truncate text-base font-black sm:text-lg">{match.home}</p>
                      <p className="truncate text-[11px] text-gray-500">{match.kickoff}</p>
                    </div>
                  </div>

                  <div className="flex min-w-[122px] flex-col items-center rounded-2xl border border-white/10 bg-[#071015] px-3 py-2">
                    {live || finished ? (
                      <>
                        <p className="text-[10px] font-bold uppercase tracking-[0.18em] text-gray-500">
                          {matchIsLive ? match.minute : "FT"}
                        </p>
                        <p className={`mt-1 text-2xl font-black ${matchIsLive ? "animate-pulse text-[#A6E824]" : "text-white"}`}>
                          {match.liveScore || "0 - 0"}
                        </p>
                      </>
                    ) : (
                      <>
                        <p className="text-[10px] font-bold uppercase tracking-[0.18em] text-gray-500">Pronostico</p>
                        <div className="mt-1 flex items-center gap-2">
                          <input
                            value={prediction.home}
                            onChange={(event) => updatePrediction(index, "home", event.target.value)}
                            disabled={submitted}
                            inputMode="numeric"
                            placeholder="-"
                            className="h-11 w-12 rounded-xl border border-white/15 bg-black text-center text-xl font-black text-white outline-none transition focus:border-[#A6E824] disabled:opacity-90"
                          />
                          <span className="text-gray-500">-</span>
                          <input
                            value={prediction.away}
                            onChange={(event) => updatePrediction(index, "away", event.target.value)}
                            disabled={submitted}
                            inputMode="numeric"
                            placeholder="-"
                            className="h-11 w-12 rounded-xl border border-white/15 bg-black text-center text-xl font-black text-white outline-none transition focus:border-[#A6E824] disabled:opacity-90"
                          />
                        </div>
                      </>
                    )}
                  </div>

                  <div className="flex min-w-0 items-center justify-end gap-2 text-right">
                    <div className="min-w-0">
                      <p className="truncate text-base font-black sm:text-lg">{match.away}</p>
                      <p className="truncate text-[11px] text-gray-500">{match.kickoff}</p>
                    </div>
                    <MatchBadge label={match.awayBadge} />
                  </div>
                </div>

                {(submitted || live || finished) && (
                  <div className="mt-3 flex items-center justify-center gap-2 rounded-2xl bg-black/35 px-3 py-2 text-sm">
                    <span className="text-gray-500">Il tuo pronostico</span>
                    <span className="font-black text-white">
                      {prediction.home || "-"} - {prediction.away || "-"}
                    </span>
                  </div>
                )}

                <BonusDots active={live || finished} />
              </div>
            );
          })}
        </div>

        <div className="sticky bottom-24 z-40 mt-5">
          {!submitted ? (
            <button
              type="button"
              onClick={submitPredictions}
              className="w-full rounded-2xl bg-[#A6E824] px-6 py-4 text-lg font-black text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
            >
              Invia pronostici
            </button>
          ) : !live && !finished ? (
            <button
              type="button"
              onClick={editPredictions}
              className="w-full rounded-2xl border border-[#A6E824]/60 bg-[#101820] px-6 py-4 text-lg font-black text-[#A6E824]"
            >
              Modifica pronostici
            </button>
          ) : null}
        </div>
      </section>

      <BottomNav onMenuClick={() => setMenuOpen(true)} />
    </main>
  );
}
