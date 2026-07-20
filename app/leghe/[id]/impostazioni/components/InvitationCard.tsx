import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { LeagueInfo } from "../types";

type Props = {
  league: LeagueInfo;
  onCopyInvite: () => void;
};

export default function InvitationCard({
  league,
  onCopyInvite,
}: Props) {
  return (
    <DashboardCard>
      <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
        Accesso
      </p>

      <h2 className="mt-2 text-2xl font-black">Inviti e identità</h2>

      <div className="mt-5 space-y-3">
        <InfoBlock label="Nome lega" value={league.name} />
        <InfoBlock label="Il tuo club" value={league.displayName} />

        <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
          <p className="text-xs font-black uppercase tracking-[0.14em] text-gray-500">
            Codice invito
          </p>
          <p className="mt-2 break-all font-mono text-lg font-black text-[#A6E824]">
            {league.inviteCode}
          </p>
        </div>
      </div>

      <button
        type="button"
        onClick={onCopyInvite}
        className="mt-5 w-full rounded-2xl bg-[#A6E824] px-5 py-3 font-black text-black transition hover:brightness-110"
      >
        Copia link invito
      </button>
    </DashboardCard>
  );
}

function InfoBlock({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <p className="text-xs font-black uppercase tracking-[0.14em] text-gray-500">
        {label}
      </p>
      <p className="mt-2 font-black text-white">{value}</p>
    </div>
  );
}
