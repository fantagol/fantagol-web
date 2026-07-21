"use client";

import { useState } from "react";

import Badge from "../../../../../components/ui/Badge";
import DashboardCard from "../../../../../components/ui/DashboardCard";

import type {
  LeagueAction,
  LeagueLifecycleState,
  LeagueMember,
} from "../types";

type Props = {
  lifecycle: LeagueLifecycleState | null;
  members: LeagueMember[];
  isAdmin: boolean;
  action: LeagueAction;
  actionMemberId: string | null;
  onAssignVice: (memberId: string) => void;
  onRemoveMember: (memberId: string, reason: string) => void;
  onReinstateMember: (memberId: string) => void;
};

export default function MembersCard({
  lifecycle,
  members,
  isAdmin,
  action,
  actionMemberId,
  onAssignVice,
  onRemoveMember,
  onReinstateMember,
}: Props) {
  const [removeTarget, setRemoveTarget] =
    useState<LeagueMember | null>(null);
  const [reason, setReason] = useState("");

  const activeMembers = members.filter((member) => member.status === "active");
  const removedMembers = members.filter(
    (member) => member.status === "removed"
  );

  function confirmRemoval() {
    if (!removeTarget) return;
    onRemoveMember(removeTarget.id, reason);
    setRemoveTarget(null);
    setReason("");
  }

  return (
    <>
      <DashboardCard>
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
              Governance
            </p>
            <h2 className="mt-2 text-2xl font-black">Membri e ruoli</h2>
          </div>
          <Badge>{lifecycle?.active_member_count ?? 0} attivi</Badge>
        </div>

        <div className="mt-5 space-y-3">
          {activeMembers.map((member) => (
            <MemberRow
              key={member.id}
              member={member}
              isAdmin={isAdmin}
              busy={Boolean(action)}
              memberBusy={actionMemberId === member.id}
              onAssignVice={() => onAssignVice(member.id)}
              onRemove={() => setRemoveTarget(member)}
            />
          ))}
        </div>

        {removedMembers.length > 0 && (
          <div className="mt-6 border-t border-white/10 pt-5">
            <p className="text-xs font-black uppercase tracking-[0.16em] text-gray-500">
              Membri rimossi
            </p>

            <div className="mt-3 space-y-3">
              {removedMembers.map((member) => (
                <div
                  key={member.id}
                  className="flex items-center justify-between gap-3 rounded-2xl border border-red-500/20 bg-red-950/10 p-4"
                >
                  <div className="min-w-0">
                    <p className="truncate font-black text-white">
                      {member.clubName}
                    </p>
                    <p className="mt-1 text-xs font-bold text-red-300">
                      Espulso
                    </p>
                  </div>

                  {isAdmin && (
                    <button
                      type="button"
                      disabled={Boolean(action)}
                      onClick={() => onReinstateMember(member.id)}
                      className="rounded-xl border border-[#A6E824]/40 px-3 py-2 text-xs font-black text-[#A6E824] disabled:opacity-40"
                    >
                      {actionMemberId === member.id &&
                      action === "reinstate-member"
                        ? "Riammissione..."
                        : "Riammetti"}
                    </button>
                  )}
                </div>
              ))}
            </div>
          </div>
        )}
      </DashboardCard>

      {removeTarget && (
        <div
          className="fixed inset-0 z-[600] flex items-center justify-center bg-black/85 px-4"
          onClick={() => setRemoveTarget(null)}
        >
          <div
            className="w-full max-w-lg rounded-3xl border border-red-500/35 bg-[#111417] p-6"
            onClick={(event) => event.stopPropagation()}
          >
            <p className="text-xs font-black uppercase tracking-[0.2em] text-red-400">
              Espulsione membro
            </p>
            <h2 className="mt-3 text-2xl font-black text-white">
              Espellere {removeTarget.clubName}?
            </h2>
            <p className="mt-3 text-sm font-semibold leading-6 text-gray-400">
              Il membro non potrà rientrare autonomamente. Lo storico già
              prodotto resterà preservato.
            </p>

            <label className="mt-5 block text-xs font-black uppercase tracking-[0.15em] text-gray-400">
              Motivazione
            </label>
            <textarea
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              rows={3}
              placeholder="Facoltativa"
              className="mt-2 w-full rounded-2xl border border-white/10 bg-black/35 px-4 py-3 text-sm font-bold text-white outline-none focus:border-red-400/60"
            />

            <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button
                type="button"
                onClick={() => setRemoveTarget(null)}
                className="rounded-xl border border-white/15 px-5 py-3 text-sm font-black text-gray-300"
              >
                Annulla
              </button>
              <button
                type="button"
                onClick={confirmRemoval}
                className="rounded-xl bg-red-600 px-5 py-3 text-sm font-black text-white"
              >
                Conferma espulsione
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

function MemberRow({
  member,
  isAdmin,
  busy,
  memberBusy,
  onAssignVice,
  onRemove,
}: {
  member: LeagueMember;
  isAdmin: boolean;
  busy: boolean;
  memberBusy: boolean;
  onAssignVice: () => void;
  onRemove: () => void;
}) {
  return (
    <div className="rounded-2xl border border-white/10 bg-black/30 p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate font-black text-white">{member.clubName}</p>
          <p className="mt-1 truncate text-xs font-semibold text-gray-500">
            {member.realName || member.displayName}
          </p>
        </div>
        <Badge variant={member.role === "admin" ? "success" : "default"}>
          {member.role === "admin"
            ? "Admin"
            : member.role === "vice"
              ? "Vice"
              : "Membro"}
        </Badge>
      </div>

      {isAdmin && member.role !== "admin" && (
        <div className="mt-4 flex flex-wrap gap-2">
          {member.role !== "vice" && (
            <button
              type="button"
              disabled={busy}
              onClick={onAssignVice}
              className="rounded-xl border border-[#A6E824]/40 px-3 py-2 text-xs font-black text-[#A6E824] disabled:opacity-40"
            >
              {memberBusy ? "Operazione..." : "Nomina Vice"}
            </button>
          )}

          <button
            type="button"
            disabled={busy}
            onClick={onRemove}
            className="rounded-xl border border-red-500/35 px-3 py-2 text-xs font-black text-red-300 disabled:opacity-40"
          >
            Espelli
          </button>
        </div>
      )}
    </div>
  );
}
