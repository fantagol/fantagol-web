import Badge from "../../../../../components/ui/Badge";
import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { LeagueInfo, LeagueLifecycleState } from "../types";
import { lifecycleLabel, lifecycleVariant } from "../utils";

type Props = {
  league: LeagueInfo;
  lifecycle: LeagueLifecycleState | null;
  isAdmin: boolean;
};

export default function AdministrationHeader({
  league,
  lifecycle,
  isAdmin,
}: Props) {
  return (
    <DashboardCard className="border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] shadow-2xl shadow-black/70">
      <div className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
          <p className="text-xs font-black uppercase tracking-[0.22em] text-[#A6E824]">
            {league.name}
          </p>

          <h1 className="mt-3 text-3xl font-black sm:text-4xl">
            Amministrazione Lega
          </h1>

          <p className="mt-3 max-w-2xl text-sm font-semibold leading-6 text-gray-400 sm:text-base">
            Centro operativo per stato della lega, iscrizioni, membri, regole,
            attività amministrative e operazioni definitive.
          </p>
        </div>

        <div className="flex flex-wrap gap-2">
          <Badge variant={isAdmin ? "success" : undefined}>
            {isAdmin ? "Admin" : league.role}
          </Badge>

          <Badge variant={lifecycleVariant(lifecycle)}>
            {lifecycleLabel(lifecycle)}
          </Badge>
        </div>
      </div>
    </DashboardCard>
  );
}
