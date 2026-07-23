import type { JsonObject, JsonValue } from "./json";

export type CommercialRuntimeRpcName =
  | "evaluate_commercial_purchase_runtime_readiness_internal"
  | "request_commercial_purchase_authorization_internal"
  | "decide_commercial_purchase_authorization_internal"
  | "get_commercial_purchase_runtime_internal"
  | "get_commercial_purchase_runtime_timeline_internal";

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
  event_type: string;
  actor: string;
  correlation_id: string;
  purchase_id: string | null;
  policy_id: string | null;
  authorization_id: string | null;
  execution_attempt_id: string | null;
  runtime_state: string | null;
  authorization_status: string | null;
  reason: string | null;
  caused_by_event_id: string | null;
  metadata: JsonObject;
  created_at: string;
  [key: string]: JsonValue | undefined;
}
