import type { LeagueLifecycleState } from "./types";

export function translateError(message: string): string {
  const translations: Array<[string, string]> = [
    [
      "ACTIVE_ADMIN_REQUIRED",
      "Questa operazione è riservata all'admin attivo della lega.",
    ],
    [
      "LEAGUE_NAME_CONFIRMATION_MISMATCH",
      "Il nome inserito non corrisponde al nome della lega.",
    ],
    [
      "LEAGUE_NOT_FOUND",
      "La lega non esiste più oppure non è accessibile.",
    ],
    ["AUTH_REQUIRED", "La sessione è scaduta. Accedi nuovamente."],
    [
      "ACTIVE_VICE_REQUIRED",
      "Prima di chiudere le iscrizioni devi nominare un Vice.",
    ],
    ["MINIMUM_TWO_ACTIVE_MEMBERS_REQUIRED", "Servono almeno due membri attivi."],
    [
      "LEAGUE_ALREADY_STARTED",
      "Il campionato è già iniziato e la lega non può essere riaperta.",
    ],
    ["LEAGUE_ALREADY_SCORED", "La lega ha già prodotto punteggi ufficiali."],
    [
      "LEAGUE_FIRST_ROUND_ALREADY_STARTED",
      "La prima giornata della lega è già iniziata.",
    ],
    ["LEAGUE_ROSTER_NOT_LOCKED", "Le iscrizioni risultano già aperte."],
    [
      "NO_FUTURE_FANTAGOL_ROUND_AVAILABLE",
      "Non esistono giornate future disponibili per avviare la lega.",
    ],
  ];

  const match = translations.find(([code]) => message.includes(code));
  return match?.[1] || message || "Operazione non riuscita.";
}

export function lifecycleLabel(
  state: LeagueLifecycleState | null
): string {
  if (!state) return "Non disponibile";
  if (state.lifecycle_status === "completed") return "Campionato concluso";
  if (state.lifecycle_status === "archived") return "Lega archiviata";
  if (state.lifecycle_status === "active") return "Campionato attivo";
  if (state.roster_status === "locked") return "Iscrizioni chiuse";
  return "Iscrizioni aperte";
}

export function lifecycleVariant(
  state: LeagueLifecycleState | null
): "default" | "success" | "warning" | "danger" {
  if (!state) return "default";
  if (state.lifecycle_status === "archived") return "danger";
  if (state.lifecycle_status === "active") return "success";
  if (state.roster_status === "locked") return "warning";
  return "success";
}

export function formatDate(value: string | null): string {
  if (!value) return "Non disponibile";

  return new Intl.DateTimeFormat("it-IT", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

export function eventLabel(action: string): string {
  const labels: Record<string, string> = {
    league_created: "Lega creata",
    member_joined: "Nuovo membro",
    member_rejoined: "Membro rientrato",
    roster_locked: "Iscrizioni chiuse",
    roster_reopened: "Iscrizioni riaperte",
    league_started: "Campionato avviato",
    league_archived: "Lega archiviata",
    vice_assigned: "Vice nominato",
    vice_revoked: "Vice revocato",
    member_removed: "Membro rimosso",
    member_reinstated: "Membro reintegrato",
    member_withdrawn: "Membro uscito",
    league_schedules_generated: "Calendari generati",
    league_schedules_regenerated: "Calendari rigenerati",
    league_schedules_preserved: "Calendari mantenuti",
    scoring_profile_changed: "Regole punteggio aggiornate",
    league_settings_changed: "Impostazioni aggiornate",
    prediction_recovery_opened: "Recovery pronostici aperto",
    prediction_recovery_used: "Recovery pronostici utilizzato",
    prediction_recovery_revoked: "Recovery pronostici revocato",
    prediction_recovery_expired: "Recovery pronostici scaduto",
    round_certification_committed: "Giornata certificata",
    round_certification_superseded: "Certificazione sostituita",
  };

  return labels[action] || action.replaceAll("_", " ");
}
