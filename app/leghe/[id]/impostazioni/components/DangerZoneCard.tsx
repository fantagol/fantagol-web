import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { LeagueAction, LeagueInfo } from "../types";

type Props = {
  league: LeagueInfo;
  isAdmin: boolean;
  action: LeagueAction;
  confirmationName: string;
  confirmationMatches: boolean;
  onConfirmationChange: (value: string) => void;
  onDelete: () => void;
};

export default function DangerZoneCard({
  league,
  isAdmin,
  action,
  confirmationName,
  confirmationMatches,
  onConfirmationChange,
  onDelete,
}: Props) {
  return (
    <DashboardCard className="mt-6 border-red-500/30 bg-gradient-to-br from-red-950/25 via-[#15191b] to-[#080909] shadow-2xl shadow-black/70">
      <div className="flex items-start gap-4">
        <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl border border-red-400/35 bg-red-500/10 text-2xl font-black text-red-400">
          !
        </div>

        <div>
          <p className="text-xs font-black uppercase tracking-[0.2em] text-red-400">
            Zona pericolosa
          </p>
          <h2 className="mt-2 text-2xl font-black">
            Elimina definitivamente la lega
          </h2>
          <p className="mt-3 text-sm font-semibold leading-6 text-gray-400">
            La cancellazione rimuove la lega e tutti i dati collegati.
            L&apos;operazione è irreversibile.
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
                Inserisci esattamente il nome della lega:
              </p>
              <p className="mt-3 rounded-xl border border-white/10 bg-[#0b0d0e] px-4 py-3 font-black text-white">
                {league.name}
              </p>
            </div>

            <label
              htmlFor="league-delete-confirmation"
              className="mt-5 block text-xs font-black uppercase tracking-[0.15em] text-gray-400"
            >
              Conferma nome lega
            </label>

            <input
              id="league-delete-confirmation"
              value={confirmationName}
              onChange={(event) => onConfirmationChange(event.target.value)}
              disabled={action === "delete"}
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
              onClick={onDelete}
              disabled={!confirmationMatches || Boolean(action)}
              className="mt-6 w-full rounded-2xl border border-red-400/40 bg-red-600 px-6 py-4 font-black text-white transition hover:bg-red-500 disabled:cursor-not-allowed disabled:border-white/10 disabled:bg-[#202426] disabled:text-gray-600"
            >
              {action === "delete"
                ? "Eliminazione in corso..."
                : "Elimina definitivamente la lega"}
            </button>
          </>
        )}
      </div>
    </DashboardCard>
  );
}
