export const LAST_LEAGUE_ID_STORAGE_KEY =
  "fantagol:last-league-id";

export type LeagueIdentity = {
  league_member_profile_id: string;
  league_member_id: string;
  league_id: string;
  membership_role: string;
  membership_status: string;
  joined_at: string;

  display_name: string;
  club_name: string;
  real_name: string | null;
  motto: string | null;

  avatar_url: string | null;
  crest_url: string | null;
  avatar_zoom: number;
  avatar_x: number;
  avatar_y: number;

  kit_template: string;
  kit_primary_color: string;
  kit_secondary_color: string;
  kit_third_color: string;
  kit_logo_mode: string;
  kit_crest_position: string;

  stars_count: number;
  total_titles: number;

  profile_version: number;
  profile_updated_at: string;
};

export type LeagueHallOfFame = {
  league_member_profile_id: string;
  league_member_id: string;
  league_id: string;

  display_name: string;
  club_name: string;

  stars_count: number;
  total_titles: number;

  fantacalcio_titles: number;
  one_to_one_titles: number;
  punti_puri_titles: number;

  profile_version: number;
  profile_updated_at: string;
};

export type LeagueMembershipSummary = {
  league_id: string;
  membership_id?: string | null;
  membership_status?: string | null;
  league_status?: string | null;
  lifecycle_status?: string | null;
  is_archived?: boolean | null;
};

export type UpdateLeagueIdentityInput = {
  leagueId: string;
  expectedProfileVersion: number;
  displayName: string;
  clubName: string;
  realName: string | null;
  motto: string | null;
  avatarUrl: string | null;
  crestUrl: string | null;
  avatarZoom: number;
  avatarX: number;
  avatarY: number;
};

export type UpdateLeagueKitInput = {
  leagueId: string;
  expectedProfileVersion: number;
  kitTemplate: string;
  kitPrimaryColor: string;
  kitSecondaryColor: string;
  kitThirdColor: string;
  kitLogoMode: string;
  kitCrestPosition: string;
};

export type LeagueIdentityWriteResult = {
  league_member_profile_id: string;
  league_member_id: string;
  league_id: string;

  display_name?: string;
  club_name?: string;
  real_name?: string | null;
  motto?: string | null;

  avatar_url?: string | null;
  crest_url?: string | null;
  avatar_zoom?: number;
  avatar_x?: number;
  avatar_y?: number;

  kit_template?: string;
  kit_primary_color?: string;
  kit_secondary_color?: string;
  kit_third_color?: string;
  kit_logo_mode?: string;
  kit_crest_position?: string;

  profile_version: number;
  profile_updated_at: string;
};
