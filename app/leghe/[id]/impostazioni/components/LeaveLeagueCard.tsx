"use client";

import { useState } from "react";

import type { LeagueAction, LeagueInfo } from "../types";

type Props = {
  league: LeagueInfo;
  activeMemberCount: number | null;
  isAdmin: boolean;
  action: LeagueAction;
  onLeaveLeague: () => void;
  onOpenMembers: () => void;
};

export default function LeaveLeagueCard({
  league,
  activeMemberCount,
  isAdmin,
  action,
  onLeaveLeague,
  onOpenMembers,
}: Props) {
  const [open, setOpen] = useState(false);
  const busy = action !== null;
  const isSoleAdmin = isAdmin && activeMemberCount === 1;

  // Per l'admin unico il flusso è assorbito dalla Danger Zone,
  // che diventa contestualmente “Abbandona e chiudi lega”.
  if (isSoleAdmin) return null;

  function closeModal() {
    if (busy) return;
    setOpen(false);
  }

  return (
    <>
      <section className="mt-6 rounded-3xl border border-amber-400/20 bg-[#111417] p-5 shadow-xl shadow-black/30 sm:p-6">
        <p className="text-xs font-black uppercase tracking-[0.2em] text-amber-300">
          Partecipazione
        </p>

        <h2 className="mt-2 text-2xl font-black">Abbandona questa lega</h2>

        <p className="mt-3 max-w-3xl text-sm font-semibold leading-6 text-gray-400">
          Uscirai soltanto da{" "}
          <strong className="text-white">{league.name}</strong>. Il tuo account
          FantaGol e le eventuali altre leghe resteranno disponibili.
        </p>

        <button
          type="button"
          disabled={busy}
          onClick={() => setOpen(true)}
          className="mt-5 w-full rounded-2xl border border-amber-400/40 bg-amber-400/10 px-5 py-3 font-black text-amber-100 transition hover:bg-amber-400/15 disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto"
        >
          Abbandona lega
        </button>
      </section>

      {open && (
        <div
          className="fixed inset-0 z-[600] flex items-center justify-center bg-black/85 px-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="leave-league-modal-title"
          onClick={closeModal}
        >
          <div
            className="w-full max-w-lg rounded-3xl border border-white/10 bg-[#111417] p-6 shadow-2xl shadow-black sm:p-7"
            onClick={(event) => event.stopPropagation()}
          >
            {isAdmin ? (
              <>
                <p className="text-xs font-black uppercase tracking-[0.2em] text-amber-300">
                  Operazione bloccata
                </p>

                <h2
                  id="leave-league-modal-title"
                  className="mt-3 text-2xl font-black"
                >
                  Trasferisci prima la carica di Admin
                </h2>

                <p className="mt-4 text-sm font-semibold leading-6 text-gray-300">
                  La lega contiene altri membri. Prima di abbandonarla devi
                  nominare un altro Admin dalla pagina Membri. Dopo il
                  trasferimento potrai uscire normalmente.
                </p>

                <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
                  <button
                    type="button"
                    onClick={closeModal}
                    className="rounded-xl border border-white/10 px-5 py-3 font-black text-gray-300 transition hover:bg-white/5"
                  >
                    Annulla
                  </button>

                  <button
                    type="button"
                    onClick={onOpenMembers}
                    className="rounded-xl bg-[#A6E824] px-5 py-3 font-black text-black transition hover:brightness-110"
                  >
                    Vai alla pagina Membri
                  </button>
                </div>
              </>
            ) : (
              <>
                <p className="text-xs font-black uppercase tracking-[0.2em] text-amber-300">
                  Conferma uscita
                </p>

                <h2
                  id="leave-league-modal-title"
                  className="mt-3 text-2xl font-black"
                >
                  Abbandonare {league.name}?
                </h2>

                <p className="mt-4 text-sm font-semibold leading-6 text-gray-300">
                  Perderai l&apos;accesso a questa lega. Potrai rientrare solo
                  attraverso un nuovo invito o, se pubblica e aperta, dal
                  catalogo delle leghe pubbliche.
                </p>

                <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
                  <button
                    type="button"
                    disabled={busy}
                    onClick={closeModal}
                    className="rounded-xl border border-white/10 px-5 py-3 font-black text-gray-300 transition hover:bg-white/5 disabled:opacity-50"
                  >
                    Annulla
                  </button>

                  <button
                    type="button"
                    disabled={busy}
                    onClick={onLeaveLeague}
                    className="rounded-xl bg-amber-500 px-5 py-3 font-black text-black transition hover:bg-amber-400 disabled:opacity-50"
                  >
                    {action === "leave-league"
                      ? "Uscita in corso..."
                      : "Conferma e abbandona"}
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </>
  );
}
