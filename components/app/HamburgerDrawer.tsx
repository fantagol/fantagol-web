"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabaseClient";
import KitPreview from "../club/KitPreview";

type HamburgerDrawerProps = {
  open: boolean;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
  onClose: () => void;
};

type DrawerLeagueData = {
  leagueId: string;
  leagueName: string;
  displayName: string;
  inviteCode: string;
  role: string;
};

type MyLeagueRpcRow = {
  league_id: string;
  membership_id?: string | null;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
  status?: string | null;
};

type LeagueLifecycleState = {
  league_id: string;
  lifecycle_status: string;
  roster_status: string;
  first_scored_at: string | null;
  starts_from_fantagol_round_id: string | null;
  first_round_lock_at: string | null;
  active_member_count: number;
  active_vice_count: number;
  schedule_version: number | null;
  schedule_roster_hash: string | null;
  schedule_member_count: number | null;
  schedule_has_bye: boolean | null;
  schedule_generated_at: string | null;
};

type LeagueActionModal =
  | { type: "close"; league: DrawerLeagueData; state: LeagueLifecycleState }
  | {
      type: "close-existing";
      league: DrawerLeagueData;
      state: LeagueLifecycleState;
      rosterChanged: boolean;
    }
  | { type: "reopen"; league: DrawerLeagueData; state: LeagueLifecycleState }
  | { type: "missing-vice"; league: DrawerLeagueData }
  | { type: "success"; title: string; message: string }
  | null;

type DrawerClubData = {
  name: string;
  motto: string | null;
  kit_template: string;
  kit_primary_color: string;
  kit_secondary_color: string;
  kit_third_color: string;
  kit_logo_mode: string;
  kit_crest_position: string;
  stars_count: number;
};


function MenuIcon({ icon }: { icon: string }) {
  const base =
    "flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-white/10 bg-[#071015]";

  if (icon === "plus") {
    return (
      <span className={base}>
        <span className="relative h-5 w-5">
          <span className="absolute left-1/2 top-0 h-full w-1 -translate-x-1/2 rounded-full bg-[#A6E824]" />
          <span className="absolute left-0 top-1/2 h-1 w-full -translate-y-1/2 rounded-full bg-[#A6E824]" />
        </span>
      </span>
    );
  }

  if (icon === "invite") {
    return (
      <span className={base}>
        <span className="relative h-5 w-6 rounded-md border border-[#A6E824]/70">
          <span className="absolute left-1 top-1 h-3 w-4 rotate-[-35deg] border-b border-l border-[#A6E824]/70" />
        </span>
      </span>
    );
  }

  if (icon === "target") {
    return (
      <span className={base}>
        <span className="flex h-6 w-6 items-center justify-center rounded-full border-2 border-[#A6E824]/80">
          <span className="flex h-3.5 w-3.5 items-center justify-center rounded-full border border-[#A6E824]/70">
            <span className="h-1.5 w-1.5 rounded-full bg-[#A6E824]" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "live") {
    return (
      <span className={base}>
        <span className="relative h-6 w-6 rounded-full border-2 border-[#A6E824]/80">
          <span className="absolute left-1/2 top-1/2 h-2 w-2 -translate-x-1/2 -translate-y-1/2 rounded-full bg-[#A6E824]" />
          <span className="absolute -right-1 -top-1 h-2.5 w-2.5 rounded-full bg-red-400" />
        </span>
      </span>
    );
  }

  if (icon === "ranking") {
    return (
      <span className={base}>
        <span className="relative h-7 w-7">
          <span className="absolute left-1/2 top-0 h-2 w-2 -translate-x-1/2 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-0 left-1/2 h-5 w-2.5 -translate-x-1/2 rounded-t bg-[#A6E824]" />
          <span className="absolute bottom-0 left-0 h-3.5 w-2.5 rounded-t bg-[#A6E824]/55" />
          <span className="absolute bottom-0 right-0 h-4 w-2.5 rounded-t bg-[#A6E824]/75" />
        </span>
      </span>
    );
  }

  if (icon === "control") {
    return (
      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-[#A6E824]/35 bg-[#A6E824]/10 shadow-[0_0_16px_rgba(166,232,36,0.18)]">
        <span className="relative h-7 w-7 rounded-lg border border-[#A6E824]/70 bg-black/40">
          <span className="absolute left-1 top-1 h-1.5 w-1.5 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-1 left-1 right-1 flex items-end gap-0.5">
            <span className="h-2 flex-1 rounded-t bg-[#A6E824]/50" />
            <span className="h-4 flex-1 rounded-t bg-[#A6E824]" />
            <span className="h-3 flex-1 rounded-t bg-[#A6E824]/70" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "stats") {
    return (
      <span className={base + " items-end gap-1 px-2 pb-2"}>
        <span className="h-3 flex-1 rounded-t bg-[#A6E824]/50" />
        <span className="h-6 flex-1 rounded-t bg-[#A6E824]" />
        <span className="h-4 flex-1 rounded-t bg-[#A6E824]/70" />
      </span>
    );
  }

  if (icon === "round") {
    return (
      <span className={base}>
        <span className="relative h-6 w-6 overflow-hidden rounded-lg border border-[#A6E824]/70 bg-black/30">
          <span className="block h-1.5 bg-[#A6E824]" />
          <span className="absolute left-1/2 top-1/2 flex h-3.5 w-3.5 -translate-x-1/2 -translate-y-[35%] items-center justify-center rounded-full border border-[#A6E824] text-[8px] font-black text-[#A6E824]">
            G
          </span>
          <span className="absolute bottom-1 left-1 h-1 w-1 rounded-full bg-white/35" />
          <span className="absolute bottom-1 right-1 h-1 w-1 rounded-full bg-white/35" />
        </span>
      </span>
    );
  }

  if (icon === "calendar") {
    return (
      <span className={base}>
        <span className="h-6 w-6 overflow-hidden rounded-md border border-[#A6E824]/70">
          <span className="block h-2 bg-[#A6E824]" />
          <span className="grid grid-cols-3 gap-0.5 p-1">
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-white/40" />
            <span className="h-1 rounded bg-[#A6E824]" />
            <span className="h-1 rounded bg-white/40" />
          </span>
        </span>
      </span>
    );
  }

  if (icon === "members") {
    return (
      <span className={base}>
        <span className="relative h-6 w-7">
          <span className="absolute left-2 top-0 h-3 w-3 rounded-full bg-[#A6E824]" />
          <span className="absolute bottom-0 left-1 h-3 w-5 rounded-t-full bg-[#A6E824]/80" />
          <span className="absolute right-0 top-2 h-2.5 w-2.5 rounded-full bg-white/50" />
          <span className="absolute bottom-0 right-0 h-2.5 w-4 rounded-t-full bg-white/30" />
        </span>
      </span>
    );
  }

  if (icon === "club") {
    return (
      <span className={base}>
        <span className="h-6 w-6 rounded-md border-2 border-[#A6E824]/80 bg-[#A6E824]/10">
          <span className="mx-auto mt-1 block h-3 w-3 rounded-full border border-[#A6E824]" />
        </span>
      </span>
    );
  }

  if (icon === "hall") {
    return (
      <span className={base}>
        <span className="relative h-6 w-6">
          <span className="absolute left-1/2 top-0 h-4 w-5 -translate-x-1/2 rounded-b-lg border-2 border-[#A6E824]" />
          <span className="absolute bottom-1 left-1/2 h-2 w-1 -translate-x-1/2 bg-[#A6E824]" />
          <span className="absolute bottom-0 left-1/2 h-1 w-5 -translate-x-1/2 rounded bg-[#A6E824]" />
        </span>
      </span>
    );
  }


  if (icon === "rules") {
    return (
      <span className={base}>
        <span className="relative h-6 w-6 rounded-md border border-[#A6E824]/75 bg-black/25">
          <span className="absolute left-1.5 top-1.5 h-0.5 w-3 rounded bg-[#A6E824]" />
          <span className="absolute left-1.5 top-3 h-0.5 w-3 rounded bg-[#A6E824]/75" />
          <span className="absolute left-1.5 top-4.5 h-0.5 w-2.5 rounded bg-[#A6E824]/50" />
          <span className="absolute -right-1 bottom-0 h-3 w-3 rotate-[-35deg] rounded-sm border border-[#A6E824] bg-[#071015]" />
        </span>
      </span>
    );
  }

  if (icon === "donate") {
    return (
      <span className={base}>
        <span className="relative h-6 w-7">
          <span className="absolute left-1/2 top-0 h-4 w-4 -translate-x-1/2 rotate-45 rounded-sm border-2 border-[#A6E824]" />
          <span className="absolute bottom-0 left-0 right-0 mx-auto h-2.5 w-6 rounded-full border border-[#A6E824]/70" />
          <span className="absolute bottom-1 left-1/2 h-1 w-3 -translate-x-1/2 rounded bg-[#A6E824]" />
        </span>
      </span>
    );
  }

  if (icon === "settings") {
    return (
      <span className={base}>
        <span className="flex h-6 w-6 items-center justify-center rounded-full border-2 border-[#A6E824]">
          <span className="h-2 w-2 rounded-full bg-[#A6E824]" />
        </span>
      </span>
    );
  }

  if (icon === "help") {
    return (
      <span className={base}>
        <span className="text-xl font-black text-[#A6E824]">?</span>
      </span>
    );
  }

  if (icon === "logout") {
    return (
      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-red-500/20 bg-red-950/20">
        <span className="relative h-5 w-5 rounded-md border-2 border-red-400">
          <span className="absolute left-3 top-2 h-1 w-3 rounded bg-red-400" />
        </span>
      </span>
    );
  }

  return <span className={base} />;
}

function DrawerMenuItem({
  icon,
  title,
  subtitle,
  danger = false,
  special = false,
  onClick,
}: {
  icon: string;
  title: string;
  subtitle?: string;
  danger?: boolean;
  special?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`group flex w-full items-center gap-3 rounded-2xl p-3 text-left transition ${
        special
          ? "border border-[#A6E824]/40 bg-[#A6E824]/10 shadow-[0_0_22px_rgba(166,232,36,0.10)] animate-pulse hover:border-[#A6E824]/80 hover:bg-[#A6E824]/15"
          : "border border-white/10 bg-black/25 hover:border-[#A6E824]/60 hover:bg-white/[0.03]"
      } ${danger ? "text-red-400" : "text-white"}`}
    >
      <MenuIcon icon={icon} />

      <span className="min-w-0 flex-1">
        <span className={`block truncate text-sm font-black ${danger ? "text-red-400" : "text-white"}`}>
          {title}
        </span>
        {subtitle && (
          <span className="mt-0.5 block truncate text-[11px] font-semibold text-gray-500">
            {subtitle}
          </span>
        )}
      </span>

      <span className={`shrink-0 text-lg font-black ${danger ? "text-red-400" : "text-[#A6E824]"}`}>
        →
      </span>
    </button>
  );
}


function LeagueLifecycleModal({
  modal,
  loading,
  onCancel,
  onConfirmClose,
  onConfirmPreserve,
  onConfirmReopen,
  onGoToMembers,
}: {
  modal: LeagueActionModal;
  loading: boolean;
  onCancel: () => void;
  onConfirmClose: () => void;
  onConfirmPreserve: () => void;
  onConfirmReopen: () => void;
  onGoToMembers: () => void;
}) {
  if (!modal) return null;

  const isOdd =
    (modal.type === "close" || modal.type === "close-existing") &&
    modal.state.active_member_count % 2 === 1;

  return (
    <div
      className="fixed inset-0 z-[500] flex items-center justify-center bg-black/80 px-4"
      onClick={loading ? undefined : onCancel}
    >
      <div
        className="w-full max-w-lg rounded-3xl border border-[#A6E824]/35 bg-[#111417] p-6 shadow-2xl shadow-black/80"
        onClick={(event) => event.stopPropagation()}
      >
        {modal.type === "close" && (
          <>
            <p className="text-xs font-black uppercase tracking-[0.25em] text-[#A6E824]">
              Chiusura iscrizioni
            </p>
            <h2 className="mt-3 text-2xl font-black text-white">
              Vuoi chiudere le iscrizioni e generare i calendari?
            </h2>

            <div className="mt-4 space-y-3 text-sm leading-6 text-gray-300">
              {isOdd ? (
                <>
                  <p>
                    La tua lega ha{" "}
                    <strong className="text-white">
                      {modal.state.active_member_count} partecipanti
                    </strong>
                    , quindi un numero dispari.
                  </p>
                  <p>
                    Verrà creato un calendario con un{" "}
                    <strong className="text-white">
                      Turno di riposo (BYE)
                    </strong>{" "}
                    a rotazione. Nessun partecipante riceverà una vittoria
                    automatica durante il proprio turno di riposo.
                  </p>
                  <p>
                    Se durante la stagione entrerà un nuovo partecipante, potrà
                    occupare il posto del Turno di riposo (BYE) dalla prima
                    giornata futura ancora aperta, senza modificare le giornate
                    già disputate o bloccate.
                  </p>
                </>
              ) : (
                <p>
                  I{" "}
                  <strong className="text-white">
                    {modal.state.active_member_count} partecipanti
                  </strong>{" "}
                  verranno bloccati e saranno generati automaticamente i
                  calendari Fantacalcio e One-to-One.
                </p>
              )}

              <p>
                La lega potrà essere riaperta solo fino all’inizio del
                campionato.
              </p>
            </div>

            <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button
                type="button"
                disabled={loading}
                onClick={onCancel}
                className="rounded-xl border border-gray-600 px-4 py-2.5 text-sm font-black text-gray-300 transition hover:border-white disabled:opacity-50"
              >
                Annulla
              </button>
              <button
                type="button"
                disabled={loading}
                onClick={onConfirmClose}
                className="rounded-xl bg-[#A6E824] px-4 py-2.5 text-sm font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {loading ? "Generazione..." : "Genera calendari"}
              </button>
            </div>
          </>
        )}

        {modal.type === "close-existing" && (
          <>
            <p className="text-xs font-black uppercase tracking-[0.25em] text-[#A6E824]">
              Nuova chiusura iscrizioni
            </p>
            <h2 className="mt-3 text-2xl font-black text-white">
              {modal.rosterChanged
                ? "Il roster è cambiato."
                : "I calendari esistono già."}
            </h2>

            <div className="mt-4 space-y-3 text-sm leading-6 text-gray-300">
              {modal.rosterChanged ? (
                <>
                  <p>
                    La composizione dei partecipanti non coincide più con quella
                    usata per generare i calendari attuali.
                  </p>
                  <p>
                    Per chiudere nuovamente le iscrizioni è quindi necessaria
                    una rigenerazione completa dei calendari Fantacalcio e
                    One-to-One.
                  </p>
                </>
              ) : (
                <>
                  <p>
                    Il roster è rimasto invariato rispetto alla generazione
                    precedente.
                  </p>
                  <p>
                    Puoi mantenere gli accoppiamenti esistenti oppure generare
                    una nuova versione completa dei calendari.
                  </p>
                </>
              )}

              {isOdd && (
                <p>
                  La lega resta dispari: continuerà a essere previsto un{" "}
                  <strong className="text-white">
                    Turno di riposo (BYE)
                  </strong>{" "}
                  a rotazione.
                </p>
              )}
            </div>

            <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:justify-end">
              <button
                type="button"
                disabled={loading}
                onClick={onCancel}
                className="rounded-xl border border-gray-600 px-4 py-2.5 text-sm font-black text-gray-300 transition hover:border-white disabled:opacity-50"
              >
                Annulla
              </button>

              {!modal.rosterChanged && (
                <button
                  type="button"
                  disabled={loading}
                  onClick={onConfirmPreserve}
                  className="rounded-xl border border-[#A6E824]/60 px-4 py-2.5 text-sm font-black text-[#A6E824] transition hover:bg-[#A6E824]/10 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {loading ? "Chiusura..." : "Mantieni calendari"}
                </button>
              )}

              <button
                type="button"
                disabled={loading}
                onClick={onConfirmClose}
                className="rounded-xl bg-[#A6E824] px-4 py-2.5 text-sm font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {loading ? "Generazione..." : "Rigenera calendari"}
              </button>
            </div>
          </>
        )}

        {modal.type === "missing-vice" && (
          <>
            <p className="text-xs font-black uppercase tracking-[0.25em] text-amber-300">
              Vice mancante
            </p>
            <h2 className="mt-3 text-2xl font-black text-white">
              Per chiudere le iscrizioni è necessario nominare un Vice.
            </h2>
            <p className="mt-4 text-sm leading-6 text-gray-300">
              Il Vice garantisce la continuità della gestione della lega in
              caso di assenza dell’Amministratore.
            </p>
            <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button
                type="button"
                onClick={onCancel}
                className="rounded-xl border border-gray-600 px-4 py-2.5 text-sm font-black text-gray-300 transition hover:border-white"
              >
                Annulla
              </button>
              <button
                type="button"
                onClick={onGoToMembers}
                className="rounded-xl bg-[#A6E824] px-4 py-2.5 text-sm font-black text-black transition hover:brightness-110"
              >
                Vai ai Membri
              </button>
            </div>
          </>
        )}

        {modal.type === "reopen" && (
          <>
            <p className="text-xs font-black uppercase tracking-[0.25em] text-[#A6E824]">
              Riapertura iscrizioni
            </p>
            <h2 className="mt-3 text-2xl font-black text-white">
              Vuoi riaprire le iscrizioni?
            </h2>
            <div className="mt-4 space-y-3 text-sm leading-6 text-gray-300">
              <p>
                Potrai aggiungere o rimuovere membri fino all’inizio del
                campionato.
              </p>
              <p>
                Se il roster cambierà, al nuovo lock i calendari dovranno essere
                rigenerati. Se resterà identico, potrai mantenerli oppure
                generarne di nuovi.
              </p>
            </div>
            <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button
                type="button"
                disabled={loading}
                onClick={onCancel}
                className="rounded-xl border border-gray-600 px-4 py-2.5 text-sm font-black text-gray-300 transition hover:border-white disabled:opacity-50"
              >
                Annulla
              </button>
              <button
                type="button"
                disabled={loading}
                onClick={onConfirmReopen}
                className="rounded-xl bg-[#A6E824] px-4 py-2.5 text-sm font-black text-black transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {loading ? "Riapertura..." : "Riapri iscrizioni"}
              </button>
            </div>
          </>
        )}

        {modal.type === "success" && (
          <>
            <p className="text-xs font-black uppercase tracking-[0.25em] text-[#A6E824]">
              Operazione completata
            </p>
            <h2 className="mt-3 text-2xl font-black text-white">
              {modal.title}
            </h2>
            <p className="mt-4 whitespace-pre-line text-sm leading-6 text-gray-300">
              {modal.message}
            </p>
            <div className="mt-6 flex justify-end">
              <button
                type="button"
                onClick={onCancel}
                className="rounded-xl bg-[#A6E824] px-5 py-2.5 text-sm font-black text-black transition hover:brightness-110"
              >
                Chiudi
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

export default function HamburgerDrawer({
  open,
  leagueName,
  displayName,
  inviteCode,
  role,
  onClose,
}: HamburgerDrawerProps) {
  const [drawerLeague, setDrawerLeague] = useState<DrawerLeagueData>({
    leagueId: "",
    leagueName,
    displayName,
    inviteCode,
    role,
  });
  const [drawerLeagues, setDrawerLeagues] = useState<DrawerLeagueData[]>([]);
  const [drawerClub, setDrawerClub] = useState<DrawerClubData | null>(null);
  const [leagueOpen, setLeagueOpen] = useState(false);
  const [lifecycleStates, setLifecycleStates] = useState<
    Record<string, LeagueLifecycleState>
  >({});
  const [leagueActionModal, setLeagueActionModal] =
    useState<LeagueActionModal>(null);
  const [leagueActionLoading, setLeagueActionLoading] = useState(false);

  useEffect(() => {
    setDrawerLeague((current) => ({
      leagueId: current.leagueId,
      leagueName,
      displayName,
      inviteCode,
      role,
    }));
  }, [leagueName, displayName, inviteCode, role]);

  function getCurrentLeagueIdFromPath() {
    const match = window.location.pathname.match(/\/leghe\/([^\/]+)/);
    return match?.[1] || "";
  }

  useEffect(() => {
    if (!open) return;

    async function loadCurrentLeague() {
      const leagueId = getCurrentLeagueIdFromPath();

      const { data, error } = await supabase.rpc("get_my_leagues_rpc");
      if (error) return;

      const leagues: DrawerLeagueData[] = (data || []).map((row: MyLeagueRpcRow) => ({
        leagueId: row.league_id || "",
        leagueName: row.league_name || "Lega FantaGol",
        displayName: row.display_name || "Club FantaGol",
        inviteCode: row.invite_code || row.league_id || "",
        role: row.role || "member",
      }));

      setDrawerLeagues(leagues);

      const stateEntries = await Promise.all(
        leagues
          .filter((item) => item.leagueId)
          .map(async (item) => {
            const { data: lifecycleData, error: lifecycleError } =
              await supabase.rpc("get_league_lifecycle_state_rpc", {
                target_league_id: item.leagueId,
              });

            if (lifecycleError) return null;

            const state = (lifecycleData || [])[0] as
              | LeagueLifecycleState
              | undefined;

            return state ? ([item.leagueId, state] as const) : null;
          })
      );

      setLifecycleStates(
        Object.fromEntries(
          stateEntries.filter(
            (
              entry
            ): entry is readonly [string, LeagueLifecycleState] => entry !== null
          )
        )
      );

      const current = leagues.find((item) => item.leagueId === leagueId) || leagues[0];
      if (!current) return;

      setDrawerLeague(current);

      const { data: clubData } = await supabase.rpc("get_my_club_rpc");
      const club = (clubData || [])[0];

      if (club) {
        setDrawerClub({
          name: club.name || current.displayName || "Club FantaGol",
          motto: club.motto || null,
          kit_template: club.kit_template || "solid",
          kit_primary_color: club.kit_primary_color || "#FFFFFF",
          kit_secondary_color: club.kit_secondary_color || "#111417",
          kit_third_color: club.kit_third_color || "#A6E824",
          kit_logo_mode: club.kit_logo_mode || "center_horizontal",
          kit_crest_position: club.kit_crest_position || "left_chest",
          stars_count: club.stars_count || 0,
        });
      }
    }

    loadCurrentLeague();
  }, [open, leagueName, displayName, inviteCode, role]);

  if (!open) return null;

  async function logout() {
    const ok = confirm("Vuoi uscire da FantaGol?");
    if (!ok) return;

    await supabase.auth.signOut();
    window.location.href = "/";
  }

  function copyInviteLink() {
    const activeInviteCode = drawerLeague.inviteCode || inviteCode;
    const inviteLink = `${window.location.origin}/invito/${activeInviteCode}`;
    navigator.clipboard.writeText(inviteLink);
    alert("Link invito copiato.");
  }

  function goTo(path: string) {
    setLeagueOpen(false);
    onClose();
    window.location.assign(path);
  }

  function getLeagueDashboardPath(targetLeagueId?: string) {
    const leagueId = targetLeagueId || getCurrentLeagueIdFromPath();
    return leagueId ? `/leghe/${leagueId}` : "/leghe";
  }

  function getLeagueRoundPath() {
    const leagueId = drawerLeague.leagueId || getCurrentLeagueIdFromPath();
    return leagueId ? `/leghe/${leagueId}/giornata` : "/leghe";
  }

  async function refreshLifecycleState(targetLeagueId: string) {
    const { data, error } = await supabase.rpc(
      "get_league_lifecycle_state_rpc",
      {
        target_league_id: targetLeagueId,
      }
    );

    if (error) throw error;

    const state = (data || [])[0] as LeagueLifecycleState | undefined;
    if (!state) return;

    setLifecycleStates((current) => ({
      ...current,
      [targetLeagueId]: state,
    }));
  }

  function getLeagueStatusPresentation(
    item: DrawerLeagueData,
    state?: LeagueLifecycleState
  ) {
    if (!state) {
      return {
        label: "Stato lega",
        clickable: false,
        pulse: false,
        tone:
          "border-gray-600/60 bg-black/40 text-gray-400",
      };
    }

    const firstLockReached =
      state.first_round_lock_at !== null &&
      // This state intentionally reflects whether the scheduled lock has elapsed.
      // eslint-disable-next-line react-hooks/purity
      new Date(state.first_round_lock_at).getTime() <= Date.now();

    const competitionActive =
      state.first_scored_at !== null ||
      state.lifecycle_status === "active" ||
      state.lifecycle_status === "completed" ||
      state.lifecycle_status === "archived" ||
      (state.roster_status === "locked" && firstLockReached);

    if (competitionActive) {
      return {
        label:
          state.lifecycle_status === "completed"
            ? "Campionato concluso"
            : "Campionato attivo",
        clickable: false,
        pulse: false,
        tone:
          "border-sky-400/30 bg-sky-400/10 text-sky-200",
      };
    }

    if (state.roster_status === "locked") {
      return {
        label: "Iscrizioni chiuse",
        clickable: item.role === "admin",
        pulse: false,
        tone:
          "border-amber-400/35 bg-amber-400/10 text-amber-200",
      };
    }

    return {
      label: "Iscrizioni aperte",
      clickable: item.role === "admin",
      pulse: item.role === "admin",
      tone:
        "border-[#A6E824]/45 bg-[#A6E824]/10 text-[#A6E824]",
    };
  }

  function handleLeagueStatusClick(
    event: React.MouseEvent<HTMLButtonElement>,
    item: DrawerLeagueData
  ) {
    event.stopPropagation();

    const state = lifecycleStates[item.leagueId];
    if (!state || item.role !== "admin") return;

    const presentation = getLeagueStatusPresentation(item, state);
    if (!presentation.clickable) return;

    if (state.roster_status === "open") {
      if (state.active_vice_count !== 1) {
        setLeagueActionModal({ type: "missing-vice", league: item });
        return;
      }

      if (state.schedule_version !== null) {
        const rosterChanged =
          state.schedule_member_count !== null &&
          state.schedule_member_count !== state.active_member_count;

        setLeagueActionModal({
          type: "close-existing",
          league: item,
          state,
          rosterChanged,
        });
        return;
      }

      setLeagueActionModal({ type: "close", league: item, state });
      return;
    }

    setLeagueActionModal({ type: "reopen", league: item, state });
  }

  async function closeLeagueWithScheduleChoice(
    regenerateSchedules: boolean
  ) {
    if (
      !leagueActionModal ||
      (leagueActionModal.type !== "close" &&
        leagueActionModal.type !== "close-existing")
    ) {
      return;
    }

    const targetLeague = leagueActionModal.league;
    setLeagueActionLoading(true);

    const { error } = await supabase.rpc("lock_league_roster_rpc", {
      target_league_id: targetLeague.leagueId,
      regenerate_schedules: regenerateSchedules,
    });

    if (error) {
      setLeagueActionLoading(false);

      if (error.message.includes("ACTIVE_VICE_REQUIRED")) {
        setLeagueActionModal({
          type: "missing-vice",
          league: targetLeague,
        });
        return;
      }

      alert(error.message);
      return;
    }

    await refreshLifecycleState(targetLeague.leagueId);
    setLeagueActionLoading(false);
    setLeagueActionModal({
      type: "success",
      title: regenerateSchedules
        ? "Calendari generati correttamente."
        : "Calendari mantenuti correttamente.",
      message: regenerateSchedules
        ? "Le iscrizioni sono state chiuse.\n\nÈ stata attivata una nuova versione dei calendari Fantacalcio e One-to-One. Potrai riaprire la lega solo fino all’inizio del campionato."
        : "Le iscrizioni sono state chiuse mantenendo gli accoppiamenti esistenti. Potrai riaprire la lega solo fino all’inizio del campionato.",
    });
  }

  function confirmCloseLeague() {
    void closeLeagueWithScheduleChoice(true);
  }

  function confirmPreserveLeagueSchedules() {
    void closeLeagueWithScheduleChoice(false);
  }

  async function confirmReopenLeague() {
    if (!leagueActionModal || leagueActionModal.type !== "reopen") return;

    const targetLeague = leagueActionModal.league;
    setLeagueActionLoading(true);

    const { error } = await supabase.rpc("reopen_league_roster_rpc", {
      target_league_id: targetLeague.leagueId,
    });

    if (error) {
      setLeagueActionLoading(false);
      alert(error.message);
      return;
    }

    await refreshLifecycleState(targetLeague.leagueId);
    setLeagueActionLoading(false);
    setLeagueActionModal({
      type: "success",
      title: "Iscrizioni riaperte.",
      message:
        "Puoi nuovamente aggiungere o rimuovere membri fino all’inizio del campionato.",
    });
  }

  const activeLeagueName = drawerLeague.leagueName || leagueName;
  const activeDisplayName = drawerLeague.displayName || displayName;
  const activeRole = drawerLeague.role || role;
  const selectableLeagues = drawerLeagues.filter((item) => item.leagueId);

  return (
    <div
      className="fixed inset-0 z-[300] flex justify-end bg-black/70 text-white"
      onClick={onClose}
    >
      <aside
        className="flex h-full w-[65vw] max-w-[360px] min-w-[260px] flex-col overflow-hidden bg-[#111417] text-white shadow-2xl shadow-black/80"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="min-w-0 border-b border-gray-800 p-4">
          {drawerClub && (
            <button
              type="button"
              onClick={() => goTo("/club")}
              className="mb-3 flex w-full items-center gap-3 rounded-2xl border border-white/10 bg-black/35 p-3 text-left transition hover:border-[#A6E824]/60 hover:bg-white/[0.03]"
            >
              <div className="flex h-20 w-16 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-[#171b1d]">
                <div className="scale-[0.38]">
                  <KitPreview
                    primary={drawerClub.kit_primary_color}
                    secondary={drawerClub.kit_secondary_color}
                    third={drawerClub.kit_third_color}
                    template={drawerClub.kit_template}
                    logoMode={drawerClub.kit_logo_mode}
                    crestPosition={drawerClub.kit_crest_position}
                    starsCount={drawerClub.stars_count}
                  />
                </div>
              </div>

              <span className="min-w-0">
                <span className="block truncate text-sm font-black text-white">
                  {drawerClub.name}
                </span>
                <span className="mt-1 line-clamp-2 block text-[11px] font-semibold leading-4 text-gray-400">
                  {drawerClub.motto || "Il tuo Club FantaGol sta per iniziare la sua storia."}
                </span>
              </span>
            </button>
          )}

          <button
            type="button"
            onClick={() => setLeagueOpen((current) => !current)}
            className="w-full rounded-2xl bg-[#A6E824] px-4 py-3 text-left text-sm font-black text-black shadow-lg shadow-[#A6E824]/20 transition hover:brightness-110"
          >
            <span className="flex items-center justify-between gap-3">
              <span className="min-w-0">
                <span className="block text-[10px] font-black uppercase tracking-[0.2em] text-black/60">Lega</span>
                <span className="block truncate">{activeLeagueName}</span>
                <span className="block truncate text-[11px] font-bold text-black/70">{activeDisplayName}</span>
              </span>
              <span className="shrink-0">{leagueOpen ? "⌃" : "⌄"}</span>
            </span>
          </button>

          {leagueOpen && selectableLeagues.length > 0 && (
            <div className="mt-2 overflow-hidden rounded-2xl border border-[#A6E824]/25 bg-[#0b1419] shadow-2xl shadow-black/50">
              {selectableLeagues.map((item) => {
                const current = item.leagueId === drawerLeague.leagueId;

                const lifecycleState = lifecycleStates[item.leagueId];
                const statusPresentation = getLeagueStatusPresentation(
                  item,
                  lifecycleState
                );

                return (
                  <div
                    key={item.leagueId}
                    className={`border-b border-white/10 px-3 py-3 last:border-b-0 ${
                      current ? "bg-[#A6E824]/10" : ""
                    }`}
                  >
                    <button
                      type="button"
                      onClick={() =>
                        goTo(getLeagueDashboardPath(item.leagueId))
                      }
                      className="flex w-full items-center justify-between gap-3 text-left text-sm font-black text-white transition hover:opacity-90"
                    >
                      <span className="min-w-0">
                        <span className="block text-[10px] font-black uppercase tracking-[0.18em] text-[#A6E824]">
                          {current ? "Lega in corso" : "Lega"}
                        </span>
                        <span className="block truncate">
                          {item.leagueName}
                        </span>
                        <span className="block truncate text-[11px] font-bold text-gray-500">
                          {item.displayName}
                        </span>
                      </span>
                      <span className="shrink-0 text-[#A6E824]">→</span>
                    </button>

                    <button
                      type="button"
                      disabled={!statusPresentation.clickable}
                      onClick={(event) =>
                        handleLeagueStatusClick(event, item)
                      }
                      className={`mt-2 inline-flex max-w-full items-center rounded-full border px-3 py-1 text-[10px] font-black uppercase tracking-[0.12em] transition ${statusPresentation.tone} ${
                        statusPresentation.pulse ? "animate-pulse" : ""
                      } ${
                        statusPresentation.clickable
                          ? "cursor-pointer hover:brightness-125"
                          : "cursor-default"
                      }`}
                    >
                      {statusPresentation.label}
                    </button>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        <nav className="flex-1 space-y-3 overflow-y-auto p-4 text-base text-white">
          <DrawerMenuItem
            icon="plus"
            title="Crea nuova lega"
            subtitle="Apri una nuova competizione"
            onClick={() => goTo("/crea-lega")}
          />

          <DrawerMenuItem
            icon="invite"
            title="Copia link invito"
            subtitle="Invita nuovi membri"
            onClick={copyInviteLink}
          />

          <div className="my-4 border-t border-gray-700" />

          <DrawerMenuItem
            icon="round"
            title="Giornata"
            subtitle="Dashboard della lega"
            onClick={() => goTo(getLeagueDashboardPath())}
          />

          <DrawerMenuItem
            icon="target"
            title="Pronostici"
            subtitle="Inserisci o modifica la giornata"
            onClick={() => goTo(getLeagueRoundPath())}
          />

          <DrawerMenuItem
            icon="live"
            title="Live"
            subtitle="Segui risultati e punti in tempo reale"
            onClick={() => goTo(getLeagueRoundPath())}
          />

          <DrawerMenuItem
            icon="ranking"
            title="Classifiche"
            subtitle="Punti Puri, Fantacalcio, One to One"
            onClick={() => goTo("/classifiche")}
          />

          <DrawerMenuItem
            icon="stats"
            title="Statistiche"
            subtitle="Schede e approfondimenti membri"
            onClick={() => goTo("/statistiche")}
          />

          <DrawerMenuItem
            icon="control"
            title="CONTROL ROOM"
            subtitle="Statistiche globali FantaGol"
            special
            onClick={() => goTo("/control-room")}
          />

          <DrawerMenuItem
            icon="calendar"
            title="Calendario"
            subtitle="Giornate chiuse, live e future"
            onClick={() => goTo("/calendario")}
          />

          <DrawerMenuItem
            icon="members"
            title="Membri"
            subtitle="Club, maglie e nomi reali"
            onClick={() => goTo("/membri")}
          />

          <div className="my-4 border-t border-gray-700" />

          <DrawerMenuItem
            icon="club"
            title="Il Mio Club"
            subtitle="Profilo, avatar e kit"
            onClick={() => goTo("/club")}
          />

          <DrawerMenuItem
            icon="hall"
            title="Hall of Fame"
            subtitle="Titoli, stelle e modalità vinte"
            onClick={() => goTo("/club?scrollTo=hall-of-fame")}
          />

          <div className="my-4 border-t border-gray-700" />

          <DrawerMenuItem
            icon="rules"
            title="Regolamento"
            subtitle="Regole ufficiali e modalità di gioco"
            onClick={() => goTo("/regolamento")}
          />

          {activeRole === "admin" && (
            <DrawerMenuItem
              icon="settings"
              title="Impostazioni Lega"
              subtitle="Gestione regole e configurazione"
              onClick={() => goTo("#")}
            />
          )}

          <div className="my-4 border-t border-gray-700" />

          <DrawerMenuItem
            icon="help"
            title="Supporto"
            subtitle="Aiuto e informazioni"
            onClick={() => goTo("#")}
          />

          <DrawerMenuItem
            icon="donate"
            title="Sostieni FantaGol"
            subtitle="Contributi liberi al progetto"
            onClick={() => goTo("/donazioni")}
          />

          <DrawerMenuItem
            icon="logout"
            title="Esci da FantaGol"
            subtitle="Logout account"
            danger
            onClick={logout}
          />
        </nav>
      </aside>

      <LeagueLifecycleModal
        modal={leagueActionModal}
        loading={leagueActionLoading}
        onCancel={() => {
          if (!leagueActionLoading) setLeagueActionModal(null);
        }}
        onConfirmClose={confirmCloseLeague}
        onConfirmPreserve={confirmPreserveLeagueSchedules}
        onConfirmReopen={confirmReopenLeague}
        onGoToMembers={() => goTo("/membri")}
      />
    </div>
  );
}

