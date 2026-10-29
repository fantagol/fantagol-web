/** R27-B: opt-in, daily, season-wide provider comparison; NEVER updates matches directly. */
import type { SupabaseClient } from "@supabase/supabase-js";
import { createHash } from "node:crypto";

type FDMatch = { id: number; matchday: number | null; utcDate: string; status: string };
type FDResponse = { matches?: FDMatch[] };
type Canonical = { id: string; sequence: number; status: string; active: boolean };

const EDITION = "2019:2026";
function checked<T>(data: T | null, error: {message: string} | null, context: string): T {
  if (error || data == null) throw new Error(`R27_${context}:${error?.message ?? "NO_DATA"}`);
  return data;
}
function tokenFromEnv(): string {
  const token = process.env.FOOTBALL_DATA_API_TOKEN ?? process.env.FOOTBALL_DATA_TOKEN ?? process.env.FOOTBALL_DATA_API_KEY;
  if (!token) throw new Error("R27_FD_TOKEN_MISSING");
  return token;
}

export async function runR27DailyCalendarSync(client: SupabaseClient, now = new Date()) {
  const { data: claims, error: claimError } = await client.rpc("r27_claim_calendar_sync_rpc");
  const claim = checked(claims,claimError,"CLAIM") as Array<{claimed:boolean;token:string|null}>;
  if (!Array.isArray(claim) || claim.length !== 1) throw new Error("R27_CLAIM_SHAPE");
  if (!claim[0].claimed) return { status: "not_due" as const, admitted: 0 };
  const leaseToken = claim[0].token;
  if (!leaseToken) throw new Error("R27_CLAIM_TOKEN_MISSING");
  let admitted = 0;
  let failure: unknown = null;
  try {
    const response = await fetch("https://api.football-data.org/v4/competitions/SA/matches?season=2026", {
      headers: {"X-Auth-Token": tokenFromEnv()}, cache:"no-store", signal: AbortSignal.timeout(18000),
    });
    if (!response.ok) throw new Error(`R27_FD_HTTP_${response.status}`);
    const body = await response.json() as FDResponse;
    if (!Array.isArray(body.matches) || body.matches.length !== 380) throw new Error("R27_FD_SEASON_INCOMPLETE");
    if (new Set(body.matches.map(m=>m.id)).size !== 380) throw new Error("R27_FD_DUPLICATE_ID");
    const byRound = new Map<number, FDMatch[]>();
    for(const m of body.matches) {
      if (!Number.isInteger(m.matchday) || m.matchday! < 1 || m.matchday! > 38) throw new Error("R27_FD_INVALID_MATCHDAY");
      const group = byRound.get(m.matchday!) ?? [];
      group.push(m); byRound.set(m.matchday!, group);
    }
    if (byRound.size !== 38 || [...byRound.values()].some(x => x.length !== 10)) throw new Error("R27_FD_ROUND_COVERAGE_INVALID");

    const { data: rounds, error: roundsError } = await client.from("fantagol_rounds")
      .select("id,sequence,status,active,opens_at,lock_at,starts_at")
      .eq("active",true).gte("sequence",1).lte("sequence",38).order("sequence");
    const eligible = checked(rounds, roundsError,"ROUNDS") as Array<Canonical & {opens_at:string|null;lock_at:string|null;starts_at:string|null}>;
    // Fail closed on duplicate active round sequence; avoid ambiguous SQL admissions.
    const activeSequences = eligible.map(r => r.sequence);
    if (new Set(activeSequences).size !== activeSequences.length) throw new Error("R27_DUPLICATE_ACTIVE_ROUND");
    const future = eligible.filter(r => ["scheduled","predictions_open"].includes(r.status)
      && r.lock_at != null && Date.parse(r.lock_at)>now.getTime()
      && r.starts_at != null && Date.parse(r.starts_at)>now.getTime());
    for (const round of future) {
      const ten = byRound.get(round.sequence);
      // Fail closed on partially confirmed FD rounds: do not mix a definitive kickoff
      // with provisional SCHEDULED timestamps. Next daily scan re-evaluates all 10.
      if (!ten || ten.some(m => m.status !== "TIMED")) continue;
      const evidence = ten.map(m=>({external_id:String(m.id),kickoff_utc:m.utcDate,provider_status:m.status}));
      if (evidence.some(m=>!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(m.kickoff_utc)
        || Date.parse(m.kickoff_utc)<=now.getTime())) continue;
      // SQL holds the round/match row locks and independently validates all 10 mappings and governance.
      // Hash actual evidence, not the date. A second correction on the SAME day
      // yields a new key, while a duplicate identical observation is idempotent.
      const fingerprint = createHash("sha256")
        .update(JSON.stringify([...evidence].sort((a,b) => a.external_id.localeCompare(b.external_id))))
        .digest("hex");
      const { data, error } = await client.rpc("r27_admit_calendar_round_rpc",{
        p_round_number:round.sequence,p_matches:evidence,
        p_idempotency_key:`r27:calendar:${EDITION}:round:${round.sequence}:sha256:${fingerprint}`,
      });
      if(error) throw new Error(`R27_ADMISSION_G${round.sequence}:${error.message}`);
      if (!Array.isArray(data)) throw new Error(`R27_ADMISSION_RESPONSE_G${round.sequence}`);
      if(data.length > 1) throw new Error(`R27_MULTIPLE_ADMISSIONS_G${round.sequence}`);
      if(data.length === 1) admitted++;
    }
    return {status:"completed" as const, admitted};
  } catch(e) { failure=e; throw e; }
  finally {
    const { data: finalized, error } = await client.rpc("r27_finalize_calendar_sync_rpc",{
      p_token:leaseToken,p_success:failure===null,
      p_error:failure instanceof Error?failure.message:"R27_SYNC_FAILED",
    });
    if(error || finalized !== true) throw new Error(`R27_FINALIZE_FAILED:${error?.message ?? "TOKEN_MISMATCH"}`);
  }
}
