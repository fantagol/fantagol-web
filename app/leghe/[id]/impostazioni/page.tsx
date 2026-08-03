"use client";

import { useParams, useRouter } from "next/navigation";

import AdminActivityCard from "./components/AdminActivityCard";
import AdministrationHeader from "./components/AdministrationHeader";
import DangerZoneCard from "./components/DangerZoneCard";
import InvitationCard from "./components/InvitationCard";
import LeagueOverviewCard from "./components/LeagueOverviewCard";
import LeaveLeagueCard from "./components/LeaveLeagueCard";
import PostponedMatchPolicyCard from "./components/PostponedMatchPolicyCard";
import RosterManagementCard from "./components/RosterManagementCard";
import ScoringProfileCard from "./components/ScoringProfileCard";
import { useLeagueAdministration } from "./hooks/useLeagueAdministration";

export default function LeagueAdministrationPage() {
  const params = useParams<{ id: string }>();
  const router = useRouter();
  const administration = useLeagueAdministration(params.id);

  if (administration.loading) {
    return (
      <main className="flex min-h-[calc(100vh-3.5rem)] items-center justify-center bg-black px-4 text-white">
        <div className="rounded-2xl border border-white/10 bg-[#111417] px-6 py-5 text-center">
          <div className="mx-auto h-8 w-8 animate-spin rounded-full border-2 border-white/10 border-t-[#A6E824]" />
          <p className="mt-4 text-sm font-black text-gray-300">
            Caricamento amministrazione...
          </p>
        </div>
      </main>
    );
  }

  if (!administration.league) return null;

  const {
    league,
    lifecycle,
    scoringProfile,
    postponedMatchPolicy,
    events,

    action,

    errorMessage,
    successMessage,
    confirmationName,
    isAdmin,
    confirmationMatches,
    rosterChanged,
    competitionStarted,
  } = administration;

  return (
    <main className="min-h-[calc(100vh-3.5rem)] bg-black text-white">
      <section className="mx-auto max-w-6xl px-4 py-6 sm:py-8">
        <AdministrationHeader
          league={league}
          lifecycle={lifecycle}
          isAdmin={isAdmin}
        />

        {(errorMessage || successMessage) && (
          <div
            className={`mt-6 rounded-2xl border px-4 py-3 text-sm font-semibold ${
              errorMessage
                ? "border-red-500/30 bg-red-950/25 text-red-200"
                : "border-[#A6E824]/30 bg-[#A6E824]/10 text-[#D9FF82]"
            }`}
          >
            {errorMessage || successMessage}
          </div>
        )}

        {!isAdmin && (
          <div className="mt-6 rounded-2xl border border-amber-400/30 bg-amber-400/10 px-4 py-4 text-sm font-semibold text-amber-100">
            Puoi consultare le informazioni della lega, ma le operazioni di
            modifica sono riservate all&apos;admin.
          </div>
        )}

        <div className="mt-6 grid gap-6 lg:grid-cols-2">
          <LeagueOverviewCard
            league={league}
            lifecycle={lifecycle}
            onBack={() => router.push(`/leghe/${league.id}`)}
          />
          <InvitationCard
            league={league}
            onCopyInvite={() => void administration.copyInviteLink()}
          />
        </div>

        <div className="mt-6 grid gap-6 lg:grid-cols-2">
          <section className="rounded-3xl border border-white/10 bg-[#111417] p-5 shadow-xl shadow-black/30 sm:p-6">
            <p className="text-xs font-black uppercase tracking-[0.2em] text-[#A6E824]">
              Governance
            </p>

            <h2 className="mt-2 text-2xl font-black">Membri e ruoli</h2>

            <p className="mt-3 text-sm font-semibold leading-6 text-gray-400">
              Nomina il Vice o un nuovo Admin, espelli un membro oppure
              riammetti un partecipante dalla pagina Membri della lega.
            </p>

            <button
              type="button"
              onClick={() => router.push(`/leghe/${league.id}/membri`)}
              className="mt-5 w-full rounded-2xl border border-[#A6E824]/50 px-5 py-3 font-black text-[#A6E824] transition hover:bg-[#A6E824]/10"
            >
              Vai alla pagina Membri
            </button>
          </section>

          <ScoringProfileCard
            scoringProfile={scoringProfile}
            isAdmin={Boolean(isAdmin)}
            action={action}
            onSave={(settings, reason) =>
              void administration.saveScoringProfile(settings, reason)
            }
          />
        </div>

        <PostponedMatchPolicyCard
          postponedMatchPolicy={postponedMatchPolicy}
          isAdmin={Boolean(isAdmin)}
          action={action}
          onSave={(policy, reason) =>
            void administration.savePostponedMatchPolicy(
              policy,
              reason,
            )
          }
        />

        <RosterManagementCard
          lifecycle={lifecycle}
          isAdmin={Boolean(isAdmin)}
          action={action}
          rosterChanged={rosterChanged}
          competitionStarted={competitionStarted}
          onLock={(regenerateSchedules) =>
            void administration.runRosterAction(regenerateSchedules)
          }
          onReopen={() => void administration.reopenRoster()}
        />

        <AdminActivityCard events={events} />

        <LeaveLeagueCard
          league={league}
          activeMemberCount={lifecycle?.active_member_count ?? null}
          isAdmin={Boolean(isAdmin)}
          action={action}
          onLeaveLeague={() => void administration.leaveLeague()}
          onOpenMembers={() => router.push(`/leghe/${league.id}/membri`)}
        />

        <DangerZoneCard
          league={league}
          isAdmin={Boolean(isAdmin)}
          isSoleAdmin={Boolean(isAdmin) && lifecycle?.active_member_count === 1}
          action={action}
          confirmationName={confirmationName}
          confirmationMatches={confirmationMatches}
          onConfirmationChange={(value) => {
            administration.setConfirmationName(value);
            administration.setErrorMessage(null);
          }}
          onCloseLeague={() => void administration.closeLeague()}
        />
      </section>
    </main>
  );
}
