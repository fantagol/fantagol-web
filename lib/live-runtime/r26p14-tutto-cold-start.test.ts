import { describe, expect, it } from "vitest";
import { isTuttoKickoffColdStart } from "./scheduler";

const kickoffAt = "2026-10-28T17:30:00.000Z";
const evaluate = (now: string, overrides: { providerCode?: string; status?: string; kickoffAt?: string } = {}) =>
  isTuttoKickoffColdStart({
    providerCode: overrides.providerCode ?? "tuttoilcalcio",
    status: overrides.status ?? "scheduled",
    kickoffAt: overrides.kickoffAt ?? kickoffAt,
    now: new Date(now),
  });

describe("R26P14 Tutto kickoff recovery boundary", () => {
  it("never polls before kickoff", () => {
    expect(evaluate("2026-10-28T17:29:59.999Z")).toBe(false);
  });
  it("allows kickoff, missed 30-minute window and delayed heartbeat", () => {
    expect(evaluate(kickoffAt)).toBe(true);
    expect(evaluate("2026-10-28T18:00:01.000Z")).toBe(true);
    expect(evaluate("2026-10-28T20:45:00.000Z")).toBe(true);
  });
  it("stops after bounded four-hour recovery", () => {
    expect(evaluate("2026-10-28T21:30:00.000Z")).toBe(true);
    expect(evaluate("2026-10-28T21:30:00.001Z")).toBe(false);
    expect(evaluate("2026-10-29T21:30:00.000Z")).toBe(false);
  });
  it("rejects other providers, non-scheduled states and invalid kickoff", () => {
    expect(evaluate(kickoffAt, {providerCode: "football_data"})).toBe(false);
    expect(evaluate(kickoffAt, {status: "finished"})).toBe(false);
    expect(evaluate(kickoffAt, {status: "live_first_half"})).toBe(false);
    expect(evaluate(kickoffAt, {kickoffAt: "INVALID"})).toBe(false);
  });
});