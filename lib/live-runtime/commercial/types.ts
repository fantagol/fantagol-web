import type {
  JsonObject,
  JsonValue,
} from "./json";

export type CommercialRuntimeRpcName =
  | "evaluate_commercial_purchase_runtime_readiness_internal"
  | "request_commercial_purchase_authorization_internal"
  | "decide_commercial_purchase_authorization_internal"
  | "get_commercial_purchase_runtime_internal"
  | "get_commercial_purchase_runtime_timeline_internal"
  | "get_my_commercial_wallet_rpc"
  | "get_my_commercial_ledger_rpc"
  | "get_commercial_products_rpc";

export interface CommercialRuntimeRpcFailure {
  rpcName: CommercialRuntimeRpcName;
  code: string | null;
  message: string;
  details: string | null;
  hint: string | null;
}

export interface CommercialRuntimeRpcResult<T> {
  data: T;
  rpcName: CommercialRuntimeRpcName;
}

export interface CommercialRuntimeEvent {
  id: string;
  purchase_id: string | null;
  policy_id: string | null;
  authorization_id: string | null;
  attempt_id: string | null;
  event_type: string;
  previous_state: string | null;
  next_state: string | null;
  actor: string;
  reason: string | null;
  correlation_id: string;
  causation_id: string | null;
  payload: JsonObject;
  occurred_at: string;
  [key: string]: JsonValue | undefined;
}
