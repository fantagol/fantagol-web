export const STRATEGY_SCHEMA_VERSION = 1 as const;

export const FANTACALCIO_PHASES = ["attack", "defense"] as const;
export type FantacalcioPhase = (typeof FANTACALCIO_PHASES)[number];

export interface FantacalcioStrategy {
  attackMatchIds: string[];
  defenseMatchIds: string[];
}

export interface FantacalcioStrategyAllocation {
  match_id: string;
  department: FantacalcioPhase;
}

export interface FantacalcioStrategyPayloadV1 {
  schema_version: typeof STRATEGY_SCHEMA_VERSION;
  allocations: FantacalcioStrategyAllocation[];
}

export interface OneToOneMatrixPair {
  sourceMatchId: string;
  targetMatchId: string;
}

export interface OneToOneMatrix {
  fixtureId: string;
  pairs: OneToOneMatrixPair[];
}

export interface OneToOneStrategyPairingV1 {
  position: number;
  own_match_id: string;
  opponent_match_id: string;
}

export interface OneToOneStrategyPayloadV1 {
  schema_version: typeof STRATEGY_SCHEMA_VERSION;
  pairings: OneToOneStrategyPairingV1[];
}

export type StrategyPayloadV1 =
  | FantacalcioStrategyPayloadV1
  | OneToOneStrategyPayloadV1;

function assertUnique(values: string[], label: string): void {
  if (new Set(values).size !== values.length) {
    throw new Error(`${label}: sono presenti elementi duplicati.`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireSchemaVersionOne(payload: unknown): asserts payload is Record<string, unknown> {
  if (!isRecord(payload) || payload.schema_version !== STRATEGY_SCHEMA_VERSION) {
    throw new Error("Versione del payload Strategy non supportata.");
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

export function toFantacalcioStrategyPayload(
  strategy: FantacalcioStrategy,
): FantacalcioStrategyPayloadV1 {
  validateFantacalcioStrategy(strategy);

  return {
    schema_version: STRATEGY_SCHEMA_VERSION,
    allocations: [
      ...strategy.attackMatchIds.map((matchId) => ({
        match_id: matchId,
        department: "attack" as const,
      })),
      ...strategy.defenseMatchIds.map((matchId) => ({
        match_id: matchId,
        department: "defense" as const,
      })),
    ],
  };
}

export function fromFantacalcioStrategyPayload(
  payload: unknown,
): FantacalcioStrategy {
  requireSchemaVersionOne(payload);

  if (!Array.isArray(payload.allocations)) {
    throw new Error("Payload Fantacalcio non valido: allocations mancante.");
  }

  const attackMatchIds: string[] = [];
  const defenseMatchIds: string[] = [];

  for (const allocation of payload.allocations) {
    if (
      !isRecord(allocation) ||
      typeof allocation.match_id !== "string" ||
      !FANTACALCIO_PHASES.includes(allocation.department as FantacalcioPhase)
    ) {
      throw new Error("Payload Fantacalcio non valido: allocation non riconosciuta.");
    }

    if (allocation.department === "attack") {
      attackMatchIds.push(allocation.match_id);
    } else {
      defenseMatchIds.push(allocation.match_id);
    }
  }

  const strategy = { attackMatchIds, defenseMatchIds };
  validateFantacalcioStrategy(strategy);

  return strategy;
}

export function toOneToOneStrategyPayload(
  matrix: OneToOneMatrix,
): OneToOneStrategyPayloadV1 {
  validateOneToOneMatrix(matrix);

  return {
    schema_version: STRATEGY_SCHEMA_VERSION,
    pairings: matrix.pairs.map((pair, index) => ({
      position: index + 1,
      own_match_id: pair.sourceMatchId,
      opponent_match_id: pair.targetMatchId,
    })),
  };
}

export function fromOneToOneStrategyPayload(
  payload: unknown,
  fixtureId: string,
): OneToOneMatrix {
  requireSchemaVersionOne(payload);

  if (!Array.isArray(payload.pairings)) {
    throw new Error("Payload One To One non valido: pairings mancante.");
  }

  const orderedPairings = payload.pairings
    .map((pairing) => {
      if (
        !isRecord(pairing) ||
        typeof pairing.position !== "number" ||
        !Number.isInteger(pairing.position) ||
        pairing.position < 1 ||
        pairing.position > 10 ||
        typeof pairing.own_match_id !== "string" ||
        typeof pairing.opponent_match_id !== "string"
      ) {
        throw new Error("Payload One To One non valido: pairing non riconosciuto.");
      }

      return {
        position: pairing.position,
        sourceMatchId: pairing.own_match_id,
        targetMatchId: pairing.opponent_match_id,
      };
    })
    .sort((left, right) => left.position - right.position);

  assertUnique(
    orderedPairings.map((pairing) => String(pairing.position)),
    "Posizioni One To One",
  );

  const matrix: OneToOneMatrix = {
    fixtureId,
    pairs: orderedPairings.map(({ sourceMatchId, targetMatchId }) => ({
      sourceMatchId,
      targetMatchId,
    })),
  };

  validateOneToOneMatrix(matrix);

  return matrix;
}
