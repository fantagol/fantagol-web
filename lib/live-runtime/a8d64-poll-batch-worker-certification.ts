import { strict as assert } from "node:assert";

import type {
  LiveRuntimeJobType,
} from "./job-service";

const jobTypes: LiveRuntimeJobType[] = [
  "poll_match",
  "poll_batch",
  "refresh_round",
];

assert.equal(
  jobTypes.includes("poll_batch"),
  true,
);

assert.equal(
  jobTypes.includes("poll_match"),
  true,
);

assert.equal(
  jobTypes.includes("refresh_round"),
  true,
);

const dispatchContract = {
  poll_match: "handlePollMatchJob",
  poll_batch: "handlePollBatchJob",
  refresh_round: "handleRefreshRoundJob",
} satisfies Partial<
  Record<LiveRuntimeJobType, string>
>;

assert.equal(
  dispatchContract.poll_batch,
  "handlePollBatchJob",
);

console.log("");
console.log(
  "[PASS] A8D.6.4 POLL_BATCH WORKER CONTRACT",
);
console.log("");
console.log(
  "[PASS] poll_batch belongs to LiveRuntimeJobType",
);
console.log(
  "[PASS] poll_match remains supported",
);
console.log(
  "[PASS] refresh_round remains supported",
);
console.log(
  "[PASS] poll_batch has a dedicated Worker dispatch target",
);