import Badge from "../../../../../components/ui/Badge";
import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { LeagueInfo, LeagueLifecycleState } from "../types";
import {
  formatDate,
  lifecycleLabel,
  lifecycleVariant,
} from "../utils";

type Props = {
  league: LeagueInfo;
  lifecycle: LeagueLifecycleState | null;
  onBack: () => void;
};

export default function LeagueOverviewCard({
  league,
  lifecycle,
  onBack,
}: Props) {
  return (
    <DashboardCard>
      <div className="flex items-center justify-between gap-4">
        <div>
          <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
            Panoramica
          </p>
          <h2 className="mt-2 text-2xl font-black">Stato della lega</h2>
        </div>

        <Badge variant={lifecycleVariant(lifecycle)}>
          {lifecycleLabel(lifecycle)}
        </Badge>
      </div>

      <div className="mt-5 grid gap-3 sm:grid-cols-3">
        <Metric label="Membri attivi">
          {lifecycle?.active_member_count ?? "—"}
        </Metric>

        <Metric label="Vice attivo">
          {lifecycle?.active_vice_count === 1 ? "Presente" : "Mancante"}
        </Metric>

        <Metric label="Turno di riposo" compact>
          {lifecycle?.schedule_has_bye ? "Previsto" : "Non previsto"}
        </Metric>
      </div>

      <div className="mt-4 rounded-2xl border border-white/10 bg-black/30 p-4 text-sm font-semibold leading-6 text-gray-400">
        <p>
          Primo lock previsto:{" "}
          <span className="font-black text-white">
            {formatDate(lifecycle?.first_round_lock_at || null)}
          </span>
        </p>

        <p className="mt-1">
          Calendario generato:{" "}
          <span className="font-black text-white">
            {formatDate(lifecycle?.schedule_generated_at || null)}
          </span>
        </p>
      </div>

      <button
        type="button"
        onClick={onBack}
        className="mt-5 w-full rounded-2xl border border-white/15 px-5 py-3 font-black text-white transition hover:border-[#A6E824]/60 hover:bg-[#A6E824]/5"
      >
        Torna alla dashboard di {league.name}
      </button>
    </DashboardCard>
  );
}

function Metric({
  label,
  compact = false,
  children,
}: {
  label: string;
  compact?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <p className="text-xs font-black uppercase tracking-[0.14em] text-gray-500">
        {label}
      </p>
      <p className={`mt-2 font-black ${compact ? "text-lg" : "text-2xl"}`}>
        {children}
      </p>
    </div>
  );
}
