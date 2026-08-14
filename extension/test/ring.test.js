import { test } from "node:test";
import assert from "node:assert/strict";
import { ringFractionForProgress, outcomeFor } from "../src/ring.js";

test("probe does not advance the ring — it means 'still thinking'", () => {
  assert.equal(ringFractionForProgress({ stage: "probe" }), null);
});

test("prompt does not advance the ring — it means 'waiting for you'", () => {
  assert.equal(ringFractionForProgress({ stage: "prompt" }), null);
});

test("download with a pct maps to a fraction", () => {
  assert.equal(ringFractionForProgress({ stage: "download", pct: 42.5 }), 0.425);
});

test("download with a missing pct leaves the ring where it is", () => {
  assert.equal(ringFractionForProgress({ stage: "download" }), null);
});

test("item maps index/total to a fraction", () => {
  assert.equal(ringFractionForProgress({ stage: "item", index: 2, total: 5 }), 0.4);
});

test("item with a zero total does not divide by zero", () => {
  assert.equal(ringFractionForProgress({ stage: "item", index: 0, total: 0 }), 0);
});

test("convert fills the ring", () => {
  assert.equal(ringFractionForProgress({ stage: "convert", mode: "remux" }), 1);
});

// Corrected, final review, Finding 4: this used to assert `save` also fills the ring,
// grouped with `convert` in the implementation — which directly contradicted
// ProgressEvent.swift's `beginsActivity` (`.save` is explicitly listed as NOT activity)
// despite this file's header claiming the two are kept in sync. `convert` already leaves
// the ring at 1 on any path that reports it; a gallery-dl-only grab has no `convert`
// stage at all (gotcha #23), so `save` there must leave the ring exactly where the last
// `item` left it rather than snapping it to 100% on a stage that isn't "download work".
test("save does not advance the ring — it's the completion flourish, not download feedback", () => {
  assert.equal(ringFractionForProgress({ stage: "save" }), null);
});

test("an unrecognised stage does not move the ring", () => {
  assert.equal(ringFractionForProgress({ stage: "something-new" }), null);
});

test("a malformed or missing event does not throw and does not move the ring", () => {
  assert.equal(ringFractionForProgress(null), null);
  assert.equal(ringFractionForProgress(undefined), null);
  assert.equal(ringFractionForProgress({}), null);
});

test("outcomeFor maps the terminal result to ok/cancelled/error", () => {
  assert.equal(outcomeFor({ result: "ok" }), "ok");
  assert.equal(outcomeFor({ result: "cancelled" }), "cancelled");
  assert.equal(outcomeFor({ result: "error" }), "error");
});

test("outcomeFor treats an unrecognised or missing result as an error, not a silent pass", () => {
  assert.equal(outcomeFor({ result: "something-else" }), "error");
  assert.equal(outcomeFor({}), "error");
});
