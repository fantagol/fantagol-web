import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { LeagueInfo, LeagueLifecycleState } from "../types";

type Props = {
  league: LeagueInfo;
  lifecycle: LeagueLifecycleState | null;
  isAdmin: boolean;
  onOpenAdminGuide: () => void;
};

export default function AdministrationHeader({
  league,
  lifecycle,
  isAdmin,
  onOpenAdminGuide,
}: Props) {
  void lifecycle;
  void isAdmin;

  return (
    <DashboardCard className="border-[#A6E824]/30 bg-gradient-to-br from-[#263033] via-[#15191b] to-[#080909] shadow-2xl shadow-black/70">
      <div className="flex flex-col gap-5">
        <div className="min-w-0">
          <p className="text-xs font-black uppercase tracking-[0.22em] text-[#A6E824]">
            {league.name}
          </p>

          <h1 className="mt-3 text-3xl font-black sm:text-4xl">
            Amministrazione Lega
          </h1>

          <p className="mt-3 max-w-2xl text-sm font-semibold leading-6 text-gray-400 sm:text-base">
            Centro operativo per stato della lega, iscrizioni, membri, regole,
            attivit? amministrative e operazioni definitive.
          </p>
        </div>

        <div className="flex justify-center">
          <button
            type="button"
            onClick={onOpenAdminGuide}
            aria-label="Apri la Guida per l'Amministratore"
            className="inline-flex min-h-10 items-center justify-center gap-2 rounded-2xl border border-[#A6E824]/40 bg-[#A6E824]/5 px-4 py-2 text-sm font-black text-[#A6E824] transition hover:border-[#A6E824]/70 hover:bg-[#A6E824]/10"
          >
            <span>Guida per l&apos;Amministratore</span>
            <span aria-hidden="true">&gt;</span>
          </button>
        </div>
      </div>
    </DashboardCard>
  );
}
