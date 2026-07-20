import Badge from "../../../../../components/ui/Badge";
import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { LeagueLifecycleState } from "../types";

type Props = {
  lifecycle: LeagueLifecycleState | null;
  onOpenMembers: () => void;
};

export default function MembersCard({
  lifecycle,
  onOpenMembers,
}: Props) {
  return (
    <DashboardCard>
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
            Governance
          </p>
          <h2 className="mt-2 text-2xl font-black">Membri e ruoli</h2>
        </div>

        <Badge>{lifecycle?.active_member_count ?? 0} membri</Badge>
      </div>

      <p className="mt-4 text-sm font-semibold leading-6 text-gray-400">
        Gestisci la composizione della lega, nomina o revoca il Vice e
        controlla lo stato dei partecipanti.
      </p>

      <div className="mt-5 rounded-2xl border border-white/10 bg-black/30 p-4">
        <p className="font-black text-white">Continuità amministrativa</p>
        <p className="mt-2 text-sm font-semibold leading-6 text-gray-500">
          {lifecycle?.active_vice_count === 1
            ? "La lega dispone di un Vice attivo."
            : "Prima della chiusura delle iscrizioni è necessario nominare un Vice."}
        </p>
      </div>

      <button
        type="button"
        onClick={onOpenMembers}
        className="mt-5 w-full rounded-2xl border border-[#A6E824]/50 px-5 py-3 font-black text-[#A6E824] transition hover:bg-[#A6E824]/10"
      >
        Apri gestione membri
      </button>
    </DashboardCard>
  );
}
