const APPLICATION_ERROR_MESSAGES: Record<string, string> = {
  AUTH_REQUIRED:
    "La sessione non è più valida. Accedi nuovamente.",

  LEAGUE_REQUIRED:
    "Non è stato possibile determinare la lega attiva.",

  EXPECTED_PROFILE_VERSION_REQUIRED:
    "La versione del profilo non è disponibile. Ricarica la pagina.",

  DISPLAY_NAME_REQUIRED:
    "Inserisci il nome con cui vuoi apparire nella lega.",

  DISPLAY_NAME_TOO_LONG:
    "Il nome scelto è troppo lungo.",

  CLUB_NAME_REQUIRED:
    "Inserisci il nome del Club.",

  CLUB_NAME_TOO_LONG:
    "Il nome del Club è troppo lungo.",

  REAL_NAME_TOO_LONG:
    "Il nome reale è troppo lungo.",

  MOTTO_TOO_LONG:
    "Il motto è troppo lungo.",

  INVALID_AVATAR_ZOOM:
    "Il livello di zoom dell’avatar non è valido.",

  INVALID_AVATAR_X:
    "La posizione orizzontale dell’avatar non è valida.",

  INVALID_AVATAR_Y:
    "La posizione verticale dell’avatar non è valida.",

  KIT_TEMPLATE_REQUIRED:
    "Seleziona un modello per il kit.",

  INVALID_PRIMARY_COLOR:
    "Il colore principale del kit non è valido.",

  INVALID_SECONDARY_COLOR:
    "Il colore secondario del kit non è valido.",

  INVALID_THIRD_COLOR:
    "Il terzo colore del kit non è valido.",

  KIT_LOGO_MODE_REQUIRED:
    "Seleziona la modalità del logo sulla maglia.",

  KIT_CREST_POSITION_REQUIRED:
    "Seleziona la posizione dello stemma.",

  ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED:
    "Non risulti membro attivo di questa lega.",

  LEAGUE_IDENTITY_PROFILE_NOT_FOUND:
    "Il profilo associato a questa lega non è disponibile.",

  LEAGUE_IDENTITY_VERSION_CONFLICT:
    "Il profilo è stato aggiornato da un’altra sessione. I dati verranno ricaricati.",
};

export class LeagueIdentityError extends Error {
  readonly code: string | null;
  readonly versionConflict: boolean;

  constructor(
    message: string,
    code: string | null = null,
  ) {
    super(message);
    this.name = "LeagueIdentityError";
    this.code = code;
    this.versionConflict =
      code === "LEAGUE_IDENTITY_VERSION_CONFLICT";
  }
}

function collectErrorText(error: unknown): string {
  if (!error || typeof error !== "object") {
    return String(error ?? "");
  }

  const candidate = error as {
    message?: unknown;
    details?: unknown;
    hint?: unknown;
    code?: unknown;
  };

  return [
    candidate.message,
    candidate.details,
    candidate.hint,
    candidate.code,
  ]
    .filter(
      (value): value is string =>
        typeof value === "string",
    )
    .join(" ");
}

export function extractLeagueIdentityErrorCode(
  error: unknown,
): string | null {
  const text = collectErrorText(error);

  for (const code of Object.keys(
    APPLICATION_ERROR_MESSAGES,
  )) {
    if (text.includes(code)) {
      return code;
    }
  }

  return null;
}

export function toLeagueIdentityError(
  error: unknown,
): LeagueIdentityError {
  if (error instanceof LeagueIdentityError) {
    return error;
  }

  const code =
    extractLeagueIdentityErrorCode(error);

  if (code) {
    return new LeagueIdentityError(
      APPLICATION_ERROR_MESSAGES[code],
      code,
    );
  }

  const fallbackText = collectErrorText(error).trim();

  return new LeagueIdentityError(
    fallbackText ||
      "Si è verificato un errore durante il caricamento del profilo della lega.",
    null,
  );
}
