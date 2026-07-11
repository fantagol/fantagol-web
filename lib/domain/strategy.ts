export const FANTACALCIO_PHASES = ["attack", "defense"] as const;
export type FantacalcioPhase = (typeof FANTACALCIO_PHASES)[number];

export interface FantacalcioStrategy {
  attackMatchIds: string[];
  defenseMatchIds: string[];
}

export interface OneToOneMatrixPair {
  sourceMatchId: string;
  targetMatchId: string;
}

export interface OneToOneMatrix {
  fixtureId: string;
  pairs: OneToOneMatrixPair[];
}

function assertUnique(values: string[], label: string): void {
  if (new Set(values).size !== values.length) {
    throw new Error(`${label}: sono presenti elementi duplicati.`);
  }
}

export function validateFantacalcioStrategy(strategy: FantacalcioStrategy): void {
  if (strategy.attackMatchIds.length !== 5 || strategy.defenseMatchIds.length !== 5) {
    throw new Error("La strategia Fantacalcio richiede 5 partite in Attacco e 5 in Difesa.");
  }

  const allMatchIds = [...strategy.attackMatchIds, ...strategy.defenseMatchIds];
  assertUnique(allMatchIds, "Strategia Fantacalcio");
}

export function validateOneToOneMatrix(matrix: OneToOneMatrix): void {
  if (matrix.pairs.length !== 10) {
    throw new Error("La matrice One To One deve contenere esattamente 10 mini-sfide.");
  }

  assertUnique(
    matrix.pairs.map((pair) => pair.sourceMatchId),
    "Pronostici propri One To One",
  );
  assertUnique(
    matrix.pairs.map((pair) => pair.targetMatchId),
    "Pronostici avversari One To One",
  );
}
