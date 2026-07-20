"use client";

import { useParams, useRouter } from "next/navigation";

import AdminActivityCard from "./components/AdminActivityCard";
import AdministrationHeader from "./components/AdministrationHeader";
import DangerZoneCard from "./components/DangerZoneCard";
import InvitationCard from "./components/InvitationCard";
import LeagueOverviewCard from "./components/LeagueOverviewCard";
import MembersCard from "./components/MembersCard";
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
        <div className="rounded-2xl border border-white/10 bg-[#111417] px-6 py-5 text-center shadow-2xl shadow-black/60">
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
          <MembersCard
            lifecycle={lifecycle}
            onOpenMembers={() => router.push("/membri")}
          />

          <ScoringProfileCard scoringProfile={scoringProfile} />
        </div>

        <RosterManagementCard
          lifecycle={lifecycle}
          isAdmin={isAdmin}
          action={action}
          rosterChanged={rosterChanged}
          competitionStarted={competitionStarted}
          onLock={(regenerateSchedules) =>
            void administration.runRosterAction(regenerateSchedules)
          }
          onReopen={() => void administration.reopenRoster()}
        />

        <AdminActivityCard events={events} />

        <DangerZoneCard
          league={league}
          isAdmin={isAdmin}
          action={action}
          confirmationName={confirmationName}
          confirmationMatches={confirmationMatches}
          onConfirmationChange={(value) => {
            administration.setConfirmationName(value);
            administration.setErrorMessage(null);
          }}
          onDelete={() => void administration.permanentlyDeleteLeague()}
        />
      </section>
    </main>
  );
}
