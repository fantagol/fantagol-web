import type { SupabaseClient } from "@supabase/supabase-js";

import {
  LAST_LEAGUE_ID_STORAGE_KEY,
  type LeagueHallOfFame,
  type LeagueIdentity,
  type LeagueIdentityWriteResult,
  type LeagueMembershipSummary,
  type UpdateLeagueIdentityInput,
  type UpdateLeagueKitInput,
} from "./types";

import {
  toLeagueIdentityError,
} from "./errors";

function firstRow<T>(
  data: T | T[] | null,
): T | null {
  if (Array.isArray(data)) {
    return data[0] ?? null;
  }

  return data;
}

function isUsableMembership(
  membership: LeagueMembershipSummary,
): boolean {
  if (!membership.league_id) {
    return false;
  }

  if (membership.is_archived === true) {
    return false;
  }

  if (
    membership.membership_status &&
    membership.membership_status !== "active"
  ) {
    return false;
  }

  if (
    membership.lifecycle_status === "archived"
  ) {
    return false;
  }

  return true;
}

export function readStoredLeagueId(): string | null {
  if (typeof window === "undefined") {
    return null;
  }

  const stored = window.localStorage
    .getItem(LAST_LEAGUE_ID_STORAGE_KEY)
    ?.trim();

  return stored || null;
}

export function storeLeagueId(
  leagueId: string,
): void {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem(
    LAST_LEAGUE_ID_STORAGE_KEY,
    leagueId,
  );
}

export function readLeagueIdFromLocation(): string | null {
  if (typeof window === "undefined") {
    return null;
  }

  const params = new URLSearchParams(
    window.location.search,
  );

  const leagueId = params.get("leagueId")?.trim();

  return leagueId || null;
}

export function buildLeagueScopedClubPath(
  path: "/club" | "/club/profilo" | "/club/kit",
  leagueId: string,
  extraParams?: Record<string, string>,
): string {
  const params = new URLSearchParams();

  params.set("leagueId", leagueId);

  for (const [key, value] of Object.entries(
    extraParams || {},
  )) {
    if (value) {
      params.set(key, value);
    }
  }

  return `${path}?${params.toString()}`;
}

export async function resolveActiveLeagueId(
  supabase: SupabaseClient,
  preferredLeagueId?: string | null,
): Promise<string> {
  const preferred = preferredLeagueId?.trim();

  const { data, error } = await supabase.rpc(
    "get_my_leagues_rpc",
  );

  if (error) {
    throw toLeagueIdentityError(error);
  }

  const memberships = (
    Array.isArray(data) ? data : []
  ) as LeagueMembershipSummary[];

  const usableMemberships =
    memberships.filter(isUsableMembership);

  if (preferred) {
    const preferredExists = usableMemberships.some(
      (membership) =>
        membership.league_id === preferred,
    );

    if (preferredExists) {
      storeLeagueId(preferred);
      return preferred;
    }
  }

  const storedLeagueId = readStoredLeagueId();

  if (storedLeagueId) {
    const storedExists = usableMemberships.some(
      (membership) =>
        membership.league_id === storedLeagueId,
    );

    if (storedExists) {
      return storedLeagueId;
    }
  }

  const fallbackLeagueId =
    usableMemberships[0]?.league_id;

  if (!fallbackLeagueId) {
    throw new Error(
      "Non risulti membro attivo di alcuna lega.",
    );
  }

  storeLeagueId(fallbackLeagueId);

  return fallbackLeagueId;
}

export async function getMyLeagueIdentity(
  supabase: SupabaseClient,
  leagueId: string,
): Promise<LeagueIdentity> {
  const { data, error } = await supabase.rpc(
    "get_my_league_identity_rpc",
    {
      target_league_id: leagueId,
    },
  );

  if (error) {
    throw toLeagueIdentityError(error);
  }

  const identity = firstRow(
    data as LeagueIdentity | LeagueIdentity[] | null,
  );

  if (!identity) {
    throw new Error(
      "Il profilo associato alla lega non è disponibile.",
    );
  }

  return identity;
}

export async function getMyLeagueHallOfFame(
  supabase: SupabaseClient,
  leagueId: string,
): Promise<LeagueHallOfFame> {
  const { data, error } = await supabase.rpc(
    "get_my_league_hall_of_fame_rpc",
    {
      target_league_id: leagueId,
    },
  );

  if (error) {
    throw toLeagueIdentityError(error);
  }

  const hallOfFame = firstRow(
    data as
      | LeagueHallOfFame
      | LeagueHallOfFame[]
      | null,
  );

  if (!hallOfFame) {
    throw new Error(
      "La Hall of Fame associata alla lega non ? disponibile.",
    );
  }

  return hallOfFame;
}

export async function updateMyLeagueIdentity(
  supabase: SupabaseClient,
  input: UpdateLeagueIdentityInput,
): Promise<LeagueIdentityWriteResult> {
  const { data, error } = await supabase.rpc(
    "update_my_league_identity_rpc",
    {
      target_league_id: input.leagueId,
      expected_profile_version:
        input.expectedProfileVersion,
      new_display_name: input.displayName,
      new_club_name: input.clubName,
      new_real_name: input.realName,
      new_motto: input.motto,
      new_avatar_url: input.avatarUrl,
      new_crest_url: input.crestUrl,
      new_avatar_zoom: input.avatarZoom,
      new_avatar_x: input.avatarX,
      new_avatar_y: input.avatarY,
    },
  );

  if (error) {
    throw toLeagueIdentityError(error);
  }

  const result = firstRow(
    data as
      | LeagueIdentityWriteResult
      | LeagueIdentityWriteResult[]
      | null,
  );

  if (!result) {
    throw new Error(
      "Il salvataggio del profilo non ha restituito alcun risultato.",
    );
  }

  return result;
}

export async function updateMyLeagueKit(
  supabase: SupabaseClient,
  input: UpdateLeagueKitInput,
): Promise<LeagueIdentityWriteResult> {
  const { data, error } = await supabase.rpc(
    "update_my_league_kit_rpc",
    {
      target_league_id: input.leagueId,
      expected_profile_version:
        input.expectedProfileVersion,
      new_kit_template: input.kitTemplate,
      new_kit_primary_color:
        input.kitPrimaryColor,
      new_kit_secondary_color:
        input.kitSecondaryColor,
      new_kit_third_color:
        input.kitThirdColor,
      new_kit_logo_mode:
        input.kitLogoMode,
      new_kit_crest_position:
        input.kitCrestPosition,
    },
  );

  if (error) {
    throw toLeagueIdentityError(error);
  }

  const result = firstRow(
    data as
      | LeagueIdentityWriteResult
      | LeagueIdentityWriteResult[]
      | null,
  );

  if (!result) {
    throw new Error(
      "Il salvataggio del kit non ha restituito alcun risultato.",
    );
  }

  return result;
}
