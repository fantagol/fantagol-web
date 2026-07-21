export type LeagueInfo = {
  id: string;
  name: string;
  displayName: string;
  inviteCode: string;
  role: string;
  status: string;
};

export type MyLeagueRpcRow = {
  league_id: string;
  membership_id?: string | null;
  league_name?: string | null;
  display_name?: string | null;
  invite_code?: string | null;
  role?: string | null;
  status?: string | null;
};

export type LeagueLifecycleState = {
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

export type ScoringProfile = {
  id: string;
  league_id?: string;
  version: number;
  surprise_bonus_enabled: boolean;
  goal_show_bonus_enabled: boolean;
  grand_slam_bonus_enabled: boolean;
  cantonata_malus_enabled: boolean;
  opposite_sign_malus_enabled: boolean;
  active: boolean;
  created_at: string;
  reason: string | null;
};

export type ScoringSettings = Pick<
  ScoringProfile,
  | "surprise_bonus_enabled"
  | "goal_show_bonus_enabled"
  | "grand_slam_bonus_enabled"
  | "cantonata_malus_enabled"
  | "opposite_sign_malus_enabled"
>;

export type AdminEvent = {
  id: string;
  action_type: string;
  actor_display_name: string | null;
  target_display_name: string | null;
  details: Record<string, unknown>;
  created_at: string;
};

export type LeagueMember = {
  id: string;
  userId: string | null;
  displayName: string;
  clubName: string;
  realName: string | null;
  role: string;
  status: string;
};

export type LeagueMembershipRpcRow = {
  membership_id: string;
  user_id: string | null;
  display_name: string | null;
  role: string | null;
  status: string | null;
  club_name: string | null;
  real_name: string | null;
};

export type LeagueAction =
  | "lock"
  | "lock-preserve"
  | "reopen"
  | "delete"
  | "save-scoring"
  | "assign-vice"
  | "remove-member"
  | "reinstate-member"
  | null;
