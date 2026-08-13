import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// ndjson.js ships with no import/export (it is loaded into the background service
// worker via importScripts() — see worker.js and ndjson.js's own header comments for
// why). Evaluating its exact source here, rather than re-implementing the same function
// a second time for tests, is what keeps this test honest about the code that actually
// ships to the worker.
const src = readFileSync(new URL("../src/ndjson.js", import.meta.url), "utf8");
const { feedNDJSON } = new Function(`${src}\nreturn { feedNDJSON };`)();

test("splits a single complete line", () => {
  const { events, buffer } = feedNDJSON("", '{"stage":"probe"}\n');
  assert.deepEqual(events, [{ stage: "probe" }]);
  assert.equal(buffer, "");
});

test("a line split across two chunks is neither dropped nor corrupted", () => {
  const first = feedNDJSON("", '{"stage":"probe"');
  assert.deepEqual(first.events, []);
  assert.equal(first.buffer, '{"stage":"probe"');

  const second = feedNDJSON(first.buffer, '}\n{"stage":"download","pct":50}\n');
  assert.deepEqual(second.events, [{ stage: "probe" }, { stage: "download", pct: 50 }]);
  assert.equal(second.buffer, "");
});

test("a chunk boundary mid-line does not merge with the next unrelated line", () => {
  // Three chunks: a complete line, then a line split right down the middle across two
  // more chunks. The complete line must not bleed into the split one.
  const a = feedNDJSON("", '{"stage":"save"}\n{"resu');
  const b = feedNDJSON(a.buffer, 'lt":"ok","message":"done.mp4"}\n');
  assert.deepEqual(a.events, [{ stage: "save" }]);
  assert.deepEqual(b.events, [{ result: "ok", message: "done.mp4" }]);
});

test("keeps a trailing partial line as the new buffer instead of dropping it", () => {
  const { events, buffer } = feedNDJSON("", '{"stage":"save"}\n{"result":"ok"');
  assert.deepEqual(events, [{ stage: "save" }]);
  assert.equal(buffer, '{"result":"ok"');
});

test("ignores blank lines", () => {
  const { events, buffer } = feedNDJSON("", "\n\n");
  assert.deepEqual(events, []);
  assert.equal(buffer, "");
});

test("skips a malformed line rather than throwing", () => {
  const { events } = feedNDJSON("", 'not json\n{"stage":"save"}\n');
  assert.deepEqual(events, [{ stage: "save" }]);
});

test("multiple events in one chunk all come out, in order", () => {
  const { events } = feedNDJSON(
    "",
    '{"stage":"probe"}\n{"stage":"item","index":1,"total":3}\n{"stage":"item","index":2,"total":3}\n'
  );
  assert.deepEqual(events, [
    { stage: "probe" },
    { stage: "item", index: 1, total: 3 },
    { stage: "item", index: 2, total: 3 },
  ]);
});
