import Badge from "../../../../../components/ui/Badge";
import DashboardCard from "../../../../../components/ui/DashboardCard";

import type { ScoringProfile } from "../types";
import { formatDate } from "../utils";

type Props = {
  scoringProfile: ScoringProfile | null;
};

export default function ScoringProfileCard({
  scoringProfile,
}: Props) {
  return (
    <DashboardCard>
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
            Regolamento
          </p>
          <h2 className="mt-2 text-2xl font-black">Profilo punteggi</h2>
        </div>

        <Badge variant="success">v{scoringProfile?.version ?? 1}</Badge>
      </div>

      <p className="mt-4 text-sm font-semibold leading-6 text-gray-400">
        I punteggi base ufficiali sono fissi. La lega può configurare
        esclusivamente l&apos;attivazione di bonus e malus.
      </p>

      <div className="mt-5 space-y-2">
        <SettingStatus
          label="Bonus Sorpresa"
          enabled={scoringProfile?.surprise_bonus_enabled ?? true}
        />
        <SettingStatus
          label="Bonus Gol Show"
          enabled={scoringProfile?.goal_show_bonus_enabled ?? true}
        />
        <SettingStatus
          label="Bonus Grande Slam"
          enabled={scoringProfile?.grand_slam_bonus_enabled ?? true}
        />
        <SettingStatus
          label="Malus Cantonata"
          enabled={scoringProfile?.cantonata_malus_enabled ?? true}
        />
        <SettingStatus
          label="Malus Segno Opposto"
          enabled={scoringProfile?.opposite_sign_malus_enabled ?? true}
        />
      </div>

      <div className="mt-5 rounded-2xl border border-white/10 bg-black/30 p-4 text-sm font-semibold text-gray-500">
        Ultima versione:{" "}
        <span className="font-black text-white">
          {formatDate(scoringProfile?.created_at || null)}
        </span>
      </div>

      <button
        type="button"
        disabled
        className="mt-5 w-full cursor-not-allowed rounded-2xl border border-white/10 bg-[#202426] px-5 py-3 font-black text-gray-600"
      >
        Modifica regole — prossima estensione
      </button>
    </DashboardCard>
  );
}

function SettingStatus({
  label,
  enabled,
}: {
  label: string;
  enabled: boolean;
}) {
  return (
    <div className="flex items-center justify-between gap-4 rounded-2xl border border-white/10 bg-black/30 px-4 py-3">
      <span className="text-sm font-bold text-gray-300">{label}</span>
      <Badge variant={enabled ? "success" : "default"}>
        {enabled ? "Attivo" : "Disattivato"}
      </Badge>
    </div>
  );
}
