export type RoundStatus =
  | "open"
  | "locked"
  | "live"
  | "finished";

export type RoundState = {
  status: RoundStatus;

  isOpen: boolean;
  isLocked: boolean;
  isLive: boolean;
  isFinished: boolean;

  firstKick: Date;
  countdownMs: number;

  label: string;
  helper: string;
};

export function getRoundState(firstKick: string): RoundState {
  const kick = new Date(firstKick);

  // ===== TEST =====
  // Metti true solo per simulare il lock.
  const FORCE_LOCKED = false;

  if (FORCE_LOCKED) {
    return {
      status: "locked",

      isOpen: false,
      isLocked: true,
      isLive: false,
      isFinished: false,

      firstKick: kick,

      countdownMs: 0,

      label: "Pronostici chiusi",

      helper: "",
    };
  }

  // ===== COMPORTAMENTO REALE =====
  const now = new Date();

  const countdownMs = kick.getTime() - now.getTime();

  let status: RoundStatus = "open";

  if (now >= kick)
    status = "locked";

  return {
    status,

    isOpen: status === "open",
    isLocked: status !== "open",
    isLive: false,
    isFinished: false,

    firstKick: kick,

    countdownMs,

    label:
      status === "open"
        ? "Pronostici aperti"
        : "Pronostici chiusi",

    helper: "",
  };
}