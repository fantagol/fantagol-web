import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("./terminal-sweep-isolated", () => ({
  runIsolatedTerminalSweep: vi.fn(),
}));
import { runIsolatedTerminalSweep } from "./terminal-sweep-isolated";
import { runProductionHeartbeat } from "./production-heartbeat-orchestrator";

const mockedSweep = vi.mocked(runIsolatedTerminalSweep);
type Input = Parameters<typeof runProductionHeartbeat>[0];
const input = (selector: () => Promise<never>): Input => ({
  client: {} as Input["client"],
  workerId: "r79-heartbeat-regression",
  dependencies: { resolveRoundContext: selector },
} satisfies Input);

describe("R79 heartbeat integration: early-return isolation", () => {
  const priorFlag = process.env.FANTAGOL_TERMINAL_SWEEP_ENABLED;
  beforeEach(() => {
    vi.clearAllMocks();
    mockedSweep.mockResolvedValue({ retryReasons: [] } as unknown as Awaited<ReturnType<typeof runIsolatedTerminalSweep>>);
  });
  afterEach(() => {
    if (priorFlag === undefined) delete process.env.FANTAGOL_TERMINAL_SWEEP_ENABLED;
    else process.env.FANTAGOL_TERMINAL_SWEEP_ENABLED = priorFlag;
  });
  it("flag OFF passes disabled to isolated sweep even when round resolution fails", async () => {
    delete process.env.FANTAGOL_TERMINAL_SWEEP_ENABLED;
    const result = await runProductionHeartbeat(input(async () => { throw new Error("selector failed"); }));
    expect(mockedSweep).toHaveBeenCalledTimes(1);
    expect(mockedSweep.mock.calls[0][0].enabled).toBe(false);
    expect(result.retryReasons).toEqual(["round_context_failed"]);
  });
  it("flag ON runs the independent sweep before a failed selector", async () => {
    process.env.FANTAGOL_TERMINAL_SWEEP_ENABLED = "true";
    const result = await runProductionHeartbeat(input(async () => { throw new Error("selector failed"); }));
    expect(mockedSweep).toHaveBeenCalledTimes(1);
    expect(mockedSweep.mock.calls[0][0].enabled).toBe(true);
    expect(result.retryRecommended).toBe(true);
  });
  it("preserves sweep diagnostics when the selector throws", async () => {
    mockedSweep.mockResolvedValue({ retryReasons: ["terminal_round_sweep_failed"] } as unknown as Awaited<ReturnType<typeof runIsolatedTerminalSweep>>);
    const result = await runProductionHeartbeat(input(async () => { throw new Error("selector failed"); }));
    expect(result.retryReasons).toContain("terminal_round_sweep_failed");
    expect(result.retryReasons).toContain("round_context_failed");
  });
  it("preserves sweep diagnostics when selector returns no round", async () => {
    mockedSweep.mockResolvedValue({ retryReasons: ["terminal_round_sweep_failed"] } as unknown as Awaited<ReturnType<typeof runIsolatedTerminalSweep>>);
    const result = await runProductionHeartbeat(input(async () => null as never));
    expect(result.retryReasons).toContain("terminal_round_sweep_failed");
    expect(result.retryReasons).toContain("round_unavailable");
  });
});
