"use client";

import { useState } from "react";

import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { LeagueAction, LeagueInfo } from "../types";

type Props = {
  league: LeagueInfo;
  isAdmin: boolean;
  isSoleAdmin: boolean;
  action: LeagueAction;
  confirmationName: string;
  confirmationMatches: boolean;
  onConfirmationChange: (value: string) => void;
  onCloseLeague: () => void;
};

export default function DangerZoneCard({
  league,
  isAdmin,
  isSoleAdmin,
  action,
  confirmationName,
  confirmationMatches,
  onConfirmationChange,
  onCloseLeague,
}: Props) {
  const [secondConfirmationOpen, setSecondConfirmationOpen] = useState(false);
  const busy = action !== null;

  function requestClosure() {
    if (!confirmationMatches || busy) return;
    setSecondConfirmationOpen(true);
  }

  function confirmClosure() {
    setSecondConfirmationOpen(false);
    onCloseLeague();
  }

  const eyebrow = isSoleAdmin ? "Uscita e chiusura" : "Chiusura lega";
  const title = isSoleAdmin
    ? "Abbandona e chiudi la lega"
    : "Chiudi questa lega";
  const buttonLabel = isSoleAdmin
    ? "Continua con abbandono e chiusura"
    : "Continua con la chiusura";

  return (
    <>
      <DashboardCard className="mt-6 border-red-500/25 bg-gradient-to-br from-red-950/20 via-[#15191b] to-[#080909] shadow-2xl shadow-black/70">
        <div className="flex items-start gap-4">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl border border-red-400/35 bg-red-500/10 text-2xl font-black text-red-400">
            !
          </div>

          <div>
            <p className="text-xs font-black uppercase tracking-[0.2em] text-red-400">
              {eyebrow}
            </p>
            <h2 className="mt-2 text-2xl font-black">{title}</h2>
            <p className="mt-3 text-sm font-semibold leading-6 text-gray-400">
              {isSoleAdmin
                ? "Sei l’unico membro attivo. Uscendo, la lega verrà chiusa e non sarà più visibile agli utenti."
                : "La chiusura rimuove la lega dall’esperienza di tutti i membri e impedisce nuove attività."}{" "}
              I dati resteranno conservati internamente per integrità, audit e
              gestione amministrativa.
            </p>
          </div>
        </div>

        <div className="mt-6 border-t border-white/10 pt-6">
          {!isAdmin ? (
            <div className="rounded-2xl border border-white/10 bg-black/35 p-5">
              <p className="font-black text-white">
                Funzione riservata all&apos;admin
              </p>
            </div>
          ) : (
            <>
              <div className="rounded-2xl border border-red-500/20 bg-black/30 p-4">
                <p className="text-sm font-semibold text-gray-300">
                  Prima conferma: inserisci esattamente il nome della lega.
                </p>
                <p className="mt-3 rounded-xl border border-white/10 bg-[#0b0d0e] px-4 py-3 font-black text-white">
                  {league.name}
                </p>
              </div>

              <label
                htmlFor="league-close-confirmation"
                className="mt-5 block text-xs font-black uppercase tracking-[0.15em] text-gray-400"
              >
                Conferma nome lega
              </label>

              <input
                id="league-close-confirmation"
                value={confirmationName}
                onChange={(event) => onConfirmationChange(event.target.value)}
                disabled={action === "close-league"}
                autoComplete="off"
                spellCheck={false}
                placeholder={league.name}
                className="mt-2 w-full rounded-2xl border border-white/10 bg-black/40 px-4 py-4 font-bold text-white outline-none transition placeholder:text-gray-700 focus:border-red-400/70 focus:ring-2 focus:ring-red-500/10"
              />

              {confirmationName.length > 0 && !confirmationMatches && (
                <p className="mt-2 text-xs font-bold text-red-300">
                  Il nome inserito non corrisponde.
                </p>
              )}

              <button
                type="button"
                onClick={requestClosure}
                disabled={!confirmationMatches || busy}
                className="mt-6 w-full rounded-2xl border border-red-400/40 bg-red-600 px-6 py-4 font-black text-white transition hover:bg-red-500 disabled:cursor-not-allowed disabled:border-white/10 disabled:bg-[#202426] disabled:text-gray-600"
              >
                {action === "close-league"
                  ? "Chiusura in corso..."
                  : buttonLabel}
              </button>
            </>
          )}
        </div>
      </DashboardCard>

      {secondConfirmationOpen && (
        <div
          className="fixed inset-0 z-[600] flex items-center justify-center bg-black/85 px-4"
          onClick={() => setSecondConfirmationOpen(false)}
        >
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="close-league-final-title"
            className="w-full max-w-lg rounded-3xl border border-red-500/40 bg-[#111417] p-6 shadow-2xl shadow-black/80"
            onClick={(event) => event.stopPropagation()}
          >
            <p className="text-xs font-black uppercase tracking-[0.22em] text-red-400">
              Conferma finale
            </p>

            <h2
              id="close-league-final-title"
              className="mt-3 text-2xl font-black text-white"
            >
              {isSoleAdmin
                ? `Abbandonare e chiudere “${league.name}”?`
                : `Chiudere davvero “${league.name}”?`}
            </h2>

            <p className="mt-4 text-sm font-semibold leading-6 text-gray-300">
              La lega non sarà più visibile né utilizzabile dai membri. I dati
              non verranno eliminati fisicamente e resteranno conservati
              internamente.
            </p>

            <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button
                type="button"
                onClick={() => setSecondConfirmationOpen(false)}
                className="rounded-xl border border-white/15 px-5 py-3 text-sm font-black text-gray-300 transition hover:border-white"
              >
                Annulla
              </button>

              <button
                type="button"
                onClick={confirmClosure}
                className="rounded-xl bg-red-600 px-5 py-3 text-sm font-black text-white transition hover:bg-red-500"
              >
                {isSoleAdmin ? "Abbandona e chiudi lega" : "Chiudi lega"}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
