"use client";

import { useState } from "react";

import DashboardCard from "../../../../../components/ui/DashboardCard";

import type {
  LeagueAction,
  PostponedMatchPolicy,
  PostponedMatchPolicyValue,
} from "../types";

type Props = {
  postponedMatchPolicy: PostponedMatchPolicy | null;
  isAdmin: boolean;
  action: LeagueAction;
  onSave: (
    policy: PostponedMatchPolicyValue,
    reason: string,
  ) => void;
};

type PolicyOption = {
  value: PostponedMatchPolicyValue;
  title: string;
  description: string;
};

const DEFAULT_POLICY: PostponedMatchPolicyValue =
  "wait_reopen_predictions";

const OPTIONS: PolicyOption[] = [
  {
    value: "wait_keep_predictions",
    title: "Attendi il recupero e mantieni i pronostici",
    description:
      "La partita resta valida. I pronostici già inseriti rimangono acquisiti e non potranno essere modificati.",
  },
  {
    value: "wait_reopen_predictions",
    title: "Attendi il recupero e riapri i pronostici",
    description:
      "Solo i pronostici della partita rinviata potranno essere inseriti o modificati fino al nuovo calcio d'inizio.",
  },
  {
    value: "exclude_from_round",
    title: "Escludi la partita dalla giornata",
    description:
      "La partita viene esclusa dal calcolo e la giornata può essere certificata senza attendere il recupero.",
  },
];

function policyKey(
  postponedMatchPolicy: PostponedMatchPolicy | null,
): string {
  if (!postponedMatchPolicy) {
    return `default:${DEFAULT_POLICY}`;
  }

  return [
    postponedMatchPolicy.policy,
    postponedMatchPolicy.policy_version,
    postponedMatchPolicy.updated_at,
  ].join(":");
}

export default function PostponedMatchPolicyCard(props: Props) {
  return (
    <PostponedMatchPolicyEditor
      key={policyKey(props.postponedMatchPolicy)}
      {...props}
    />
  );
}

function PostponedMatchPolicyEditor({
  postponedMatchPolicy,
  isAdmin,
  action,
  onSave,
}: Props) {
  const persistedPolicy =
    postponedMatchPolicy?.policy ?? DEFAULT_POLICY;

  const [selectedPolicy, setSelectedPolicy] =
    useState<PostponedMatchPolicyValue>(persistedPolicy);

  const [reason, setReason] = useState("");

  const changed = selectedPolicy !== persistedPolicy;
  const busy = action !== null;

  return (
    <DashboardCard className="mt-6">
      <div>
        <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
          Casi speciali
        </p>

        <h2 className="mt-2 text-2xl font-black">
          Gestione partite rinviate
        </h2>
      </div>

      <p className="mt-4 max-w-4xl text-sm font-semibold leading-6 text-gray-400">
        Scegli come FantaGol deve gestire una partita rinviata. La
        regola viene applicata solo alla partita interessata: tutti gli
        altri pronostici della giornata restano acquisiti.
      </p>

      <p className="mt-3 max-w-4xl text-sm font-semibold leading-6 text-gray-400">
        L&apos;Amministratore può modificare questa impostazione in
        qualsiasi momento per adattarla alle esigenze della lega. Se
        una partita rinviata è già in gestione, l&apos;eventuale cambio
        di modalità richiederà una conferma prima di essere applicato.
      </p>

      <div
        className="mt-6 space-y-3"
        role="radiogroup"
        aria-label="Modalità di gestione delle partite rinviate"
      >
        {OPTIONS.map((option) => {
          const selected = selectedPolicy === option.value;

          return (
            <button
              key={option.value}
              type="button"
              role="radio"
              aria-checked={selected}
              disabled={!isAdmin || busy}
              onClick={() => setSelectedPolicy(option.value)}
              className={`flex w-full items-start gap-4 rounded-2xl border px-4 py-4 text-left transition ${
                selected
                  ? "border-[#A6E824]/70 bg-[#A6E824]/10"
                  : "border-white/10 bg-black/30 hover:border-[#A6E824]/35"
              } disabled:cursor-default`}
            >
              <span
                aria-hidden="true"
                className={`mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full border-2 transition ${
                  selected
                    ? "border-[#A6E824] bg-[#A6E824]"
                    : "border-gray-600 bg-black/30"
                }`}
              >
                {selected && (
                  <span className="h-2.5 w-2.5 rounded-full bg-black" />
                )}
              </span>

              <span className="min-w-0">
                <span
                  className={`block font-black ${
                    selected ? "text-white" : "text-gray-300"
                  }`}
                >
                  {option.title}
                </span>

                <span className="mt-2 block text-sm font-semibold leading-6 text-gray-500">
                  {option.description}
                </span>
              </span>
            </button>
          );
        })}
      </div>

      {!isAdmin && (
        <div className="mt-5 rounded-2xl border border-white/10 bg-black/30 p-4 text-sm font-semibold text-gray-500">
          La modalità è consultabile da tutti i partecipanti, ma può
          essere modificata soltanto dall&apos;Admin.
        </div>
      )}

      {isAdmin && (
        <>
          <label
            htmlFor="postponed-match-policy-reason"
            className="mt-5 block text-xs font-black uppercase tracking-[0.15em] text-gray-400"
          >
            Motivo della modifica
          </label>

          <input
            id="postponed-match-policy-reason"
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            disabled={busy}
            maxLength={500}
            placeholder="Facoltativo"
            className="mt-2 w-full rounded-2xl border border-white/10 bg-black/35 px-4 py-3 text-sm font-bold text-white outline-none transition focus:border-[#A6E824]/60"
          />

          <button
            type="button"
            disabled={!changed || busy}
            onClick={() => onSave(selectedPolicy, reason)}
            className="mt-5 w-full rounded-2xl bg-[#A6E824] px-5 py-3 font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:bg-[#202426] disabled:text-gray-600"
          >
            {action === "save-postponed-policy"
              ? "Salvataggio..."
              : "Salva impostazione"}
          </button>
        </>
      )}
</DashboardCard>
  );
}
