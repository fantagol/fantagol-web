import Badge from "../../../../../components/ui/Badge";
import DashboardCard from "../../../../../components/ui/DashboardCard";

import type {
  LeagueAction,
  LeagueLifecycleState,
} from "../types";
import { lifecycleLabel, lifecycleVariant } from "../utils";

type Props = {
  lifecycle: LeagueLifecycleState | null;
  isAdmin: boolean;
  action: LeagueAction;
  rosterChanged: boolean;
  competitionStarted: boolean;
  onLock: (regenerateSchedules: boolean) => void;
  onReopen: () => void;
};

export default function RosterManagementCard({
  lifecycle,
  isAdmin,
  action,
  rosterChanged,
  competitionStarted,
  onLock,
  onReopen,
}: Props) {
  return (
    <DashboardCard className="mt-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
            Gestione operativa
          </p>
          <h2 className="mt-2 text-2xl font-black">
            Iscrizioni e calendari
          </h2>
          <p className="mt-3 max-w-3xl text-sm font-semibold leading-6 text-gray-400">
            Le operazioni rispettano automaticamente i vincoli del motore:
            presenza del Vice, almeno due membri, nessun punteggio ufficiale e
            campionato non ancora avviato.
          </p>
        </div>

        <Badge variant={lifecycleVariant(lifecycle)}>
          {lifecycleLabel(lifecycle)}
        </Badge>
      </div>

      {!isAdmin ? (
        <div className="mt-5 rounded-2xl border border-white/10 bg-black/30 p-5 text-sm font-semibold text-gray-500">
          Operazioni riservate all&apos;admin.
        </div>
      ) : competitionStarted ? (
        <div className="mt-5 rounded-2xl border border-sky-400/20 bg-sky-400/10 p-5">
          <p className="font-black text-sky-100">Campionato avviato</p>
          <p className="mt-2 text-sm font-semibold leading-6 text-sky-100/70">
            La composizione della lega e i calendari non sono più
            modificabili da questa sezione.
          </p>
        </div>
      ) : lifecycle?.roster_status === "open" ? (
        <div className="mt-5 grid gap-3 md:grid-cols-2">
          <button
            type="button"
            disabled={
              Boolean(action) ||
              lifecycle.active_member_count < 2 ||
              lifecycle.active_vice_count !== 1
            }
            onClick={() => onLock(true)}
            className="rounded-2xl bg-[#A6E824] px-5 py-4 font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:bg-[#202426] disabled:text-gray-600"
          >
            {action === "lock"
              ? "Generazione in corso..."
              : lifecycle.schedule_version
                ? "Chiudi e rigenera calendari"
                : "Chiudi iscrizioni e genera calendari"}
          </button>

          {lifecycle.schedule_version !== null && !rosterChanged && (
            <button
              type="button"
              disabled={Boolean(action)}
              onClick={() => onLock(false)}
              className="rounded-2xl border border-[#A6E824]/50 px-5 py-4 font-black text-[#A6E824] transition hover:bg-[#A6E824]/10 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {action === "lock-preserve"
                ? "Chiusura in corso..."
                : "Chiudi mantenendo i calendari"}
            </button>
          )}
        </div>
      ) : (
        <button
          type="button"
          disabled={Boolean(action)}
          onClick={onReopen}
          className="mt-5 w-full rounded-2xl border border-[#A6E824]/50 px-5 py-4 font-black text-[#A6E824] transition hover:bg-[#A6E824]/10 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {action === "reopen"
            ? "Riapertura in corso..."
            : "Riapri iscrizioni"}
        </button>
      )}

      {isAdmin &&
        lifecycle?.roster_status === "open" &&
        lifecycle.active_vice_count !== 1 && (
          <p className="mt-3 text-sm font-semibold text-amber-300">
            Nomina un Vice prima di chiudere le iscrizioni.
          </p>
        )}
    </DashboardCard>
  );
}
