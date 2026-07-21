"use client";

import { useState } from "react";

import Badge from "../../../../../components/ui/Badge";
import DashboardCard from "../../../../../components/ui/DashboardCard";

import type {
  LeagueAction,
  ScoringProfile,
  ScoringSettings,
} from "../types";
import { formatDate } from "../utils";

type Props = {
  scoringProfile: ScoringProfile | null;
  isAdmin: boolean;
  action: LeagueAction;
  onSave: (settings: ScoringSettings, reason: string) => void;
};

const DEFAULT_SETTINGS: ScoringSettings = {
  surprise_bonus_enabled: true,
  goal_show_bonus_enabled: true,
  grand_slam_bonus_enabled: true,
  cantonata_malus_enabled: true,
  opposite_sign_malus_enabled: true,
};

const SCORING_SETTING_KEYS: Array<keyof ScoringSettings> = [
  "surprise_bonus_enabled",
  "goal_show_bonus_enabled",
  "grand_slam_bonus_enabled",
  "cantonata_malus_enabled",
  "opposite_sign_malus_enabled",
];

function getSettingsFromProfile(
  scoringProfile: ScoringProfile | null
): ScoringSettings {
  if (!scoringProfile) {
    return { ...DEFAULT_SETTINGS };
  }

  return {
    surprise_bonus_enabled: scoringProfile.surprise_bonus_enabled,
    goal_show_bonus_enabled: scoringProfile.goal_show_bonus_enabled,
    grand_slam_bonus_enabled: scoringProfile.grand_slam_bonus_enabled,
    cantonata_malus_enabled: scoringProfile.cantonata_malus_enabled,
    opposite_sign_malus_enabled:
      scoringProfile.opposite_sign_malus_enabled,
  };
}

function getProfileKey(scoringProfile: ScoringProfile | null): string {
  if (!scoringProfile) {
    return "default";
  }

  return [
    scoringProfile.version,
    scoringProfile.created_at,
    scoringProfile.surprise_bonus_enabled,
    scoringProfile.goal_show_bonus_enabled,
    scoringProfile.grand_slam_bonus_enabled,
    scoringProfile.cantonata_malus_enabled,
    scoringProfile.opposite_sign_malus_enabled,
  ].join(":");
}

export default function ScoringProfileCard(props: Props) {
  return (
    <ScoringProfileEditor
      key={getProfileKey(props.scoringProfile)}
      {...props}
    />
  );
}

function ScoringProfileEditor({
  scoringProfile,
  isAdmin,
  action,
  onSave,
}: Props) {
  const [settings, setSettings] = useState<ScoringSettings>(() =>
    getSettingsFromProfile(scoringProfile)
  );
  const [reason, setReason] = useState("");

  let changed = false;

  if (scoringProfile) {
    const persistedSettings = getSettingsFromProfile(scoringProfile);

    changed = SCORING_SETTING_KEYS.some(
      (key) => persistedSettings[key] !== settings[key]
    );
  }

  function toggle(key: keyof ScoringSettings) {
    if (!isAdmin || action) return;

    setSettings((current) => {
      if (key === "goal_show_bonus_enabled") {
        const nextGoalShow = !current.goal_show_bonus_enabled;

        return {
          ...current,
          goal_show_bonus_enabled: nextGoalShow,
          grand_slam_bonus_enabled: nextGoalShow
            ? current.grand_slam_bonus_enabled
            : false,
        };
      }

      if (
        key === "grand_slam_bonus_enabled" &&
        !current.goal_show_bonus_enabled
      ) {
        return current;
      }

      return { ...current, [key]: !current[key] };
    });
  }

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
        I punteggi base ufficiali restano fissi. L&apos;admin può attivare
        o disattivare bonus e malus creando una nuova versione.
      </p>

      <div className="mt-5 space-y-2">
        <Toggle
          label="Bonus Sorpresa"
          enabled={settings.surprise_bonus_enabled}
          disabled={!isAdmin || Boolean(action)}
          onClick={() => toggle("surprise_bonus_enabled")}
        />
        <Toggle
          label="Bonus Gol Show"
          enabled={settings.goal_show_bonus_enabled}
          disabled={!isAdmin || Boolean(action)}
          onClick={() => toggle("goal_show_bonus_enabled")}
        />
        <Toggle
          label="Bonus Grande Slam"
          enabled={settings.grand_slam_bonus_enabled}
          disabled={
            !isAdmin ||
            Boolean(action) ||
            !settings.goal_show_bonus_enabled
          }
          helper={
            settings.goal_show_bonus_enabled
              ? undefined
              : "Richiede Bonus Gol Show attivo"
          }
          onClick={() => toggle("grand_slam_bonus_enabled")}
        />
        <Toggle
          label="Malus Cantonata"
          enabled={settings.cantonata_malus_enabled}
          disabled={!isAdmin || Boolean(action)}
          onClick={() => toggle("cantonata_malus_enabled")}
        />
        <Toggle
          label="Malus Segno Opposto"
          enabled={settings.opposite_sign_malus_enabled}
          disabled={!isAdmin || Boolean(action)}
          onClick={() => toggle("opposite_sign_malus_enabled")}
        />
      </div>

      {isAdmin && (
        <>
          <label className="mt-5 block text-xs font-black uppercase tracking-[0.15em] text-gray-400">
            Motivo della modifica
          </label>
          <input
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder="Facoltativo"
            disabled={Boolean(action)}
            className="mt-2 w-full rounded-2xl border border-white/10 bg-black/35 px-4 py-3 text-sm font-bold text-white outline-none focus:border-[#A6E824]/60"
          />

          <button
            type="button"
            disabled={!changed || Boolean(action)}
            onClick={() => onSave(settings, reason)}
            className="mt-5 w-full rounded-2xl bg-[#A6E824] px-5 py-3 font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:bg-[#202426] disabled:text-gray-600"
          >
            {action === "save-scoring"
              ? "Salvataggio..."
              : "Salva nuova versione"}
          </button>
        </>
      )}

      <div className="mt-5 rounded-2xl border border-white/10 bg-black/30 p-4 text-sm font-semibold text-gray-500">
        Ultima versione:{" "}
        <span className="font-black text-white">
          {formatDate(scoringProfile?.created_at || null)}
        </span>
      </div>
    </DashboardCard>
  );
}

function Toggle({
  label,
  enabled,
  disabled,
  helper,
  onClick,
}: {
  label: string;
  enabled: boolean;
  disabled: boolean;
  helper?: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={onClick}
      className="flex w-full items-center justify-between gap-4 rounded-2xl border border-white/10 bg-black/30 px-4 py-3 text-left transition hover:border-[#A6E824]/40 disabled:cursor-default"
    >
      <span className="min-w-0">
        <span className="block text-sm font-bold text-gray-300">{label}</span>
        {helper && (
          <span className="mt-1 block text-[11px] font-semibold text-amber-300">
            {helper}
          </span>
        )}
      </span>
      <span
        className={`relative h-7 w-12 rounded-full transition ${
          enabled ? "bg-[#A6E824]" : "bg-gray-700"
        }`}
      >
        <span
          className={`absolute top-1 h-5 w-5 rounded-full bg-black transition ${
            enabled ? "left-6" : "left-1"
          }`}
        />
      </span>
    </button>
  );
}
