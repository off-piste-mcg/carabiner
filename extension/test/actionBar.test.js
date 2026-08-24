import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { JSDOM } from "jsdom";
import { findSaveButton, saveAnchorPosition } from "../src/actionBar.js";

// Driven by the REAL captured fixtures, never hand-written markup — gotcha #31: a fixture
// you authored tests your own assumptions, and that is precisely how shortcode.js shipped
// a regex that matched nothing on a profile grid while 42 tests stayed green.
//
// The Save button is found structurally (a <section> with >= 3 icon buttons; Save is the
// last) rather than by `aria-label`, which is LOCALIZED — these fixtures say "Opslaan",
// not "Save". The tests assert the Dutch label only to prove the structural rule landed on
// the right element; nothing in the source reads a label.

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = (name) =>
  new JSDOM(readFileSync(path.join(here, "fixtures", name), "utf8")).window.document;

const labelOf = (el) =>
  el.getAttribute("aria-label") ?? el.querySelector("[aria-label]")?.getAttribute("aria-label");

test("a feed post's five-button action bar resolves to Save", () => {
  const doc = fixture("feed-post.html");
  const found = findSaveButton(doc.body);
  assert.ok(found, "the feed fixture has an action bar and must resolve one");
  assert.equal(labelOf(found), "Opslaan");
});

test("a permalink's FOUR-button bar also resolves to Save — share is absent there", () => {
  // Measured: the permalink fixture's bar carries like/comment/repost/save and no share
  // button, which is why the threshold has to sit below four.
  const doc = fixture("permalink.html");
  const found = findSaveButton(doc.body);
  assert.ok(found);
  assert.equal(labelOf(found), "Opslaan");
});

test("fourteen comment-like buttons do not pull the search off the action bar", () => {
  // permalink.html has one like button per comment. Any rule that swept up icon buttons
  // without the per-section threshold would land on a comment, and the button would attach
  // itself to the wrong row entirely.
  const doc = fixture("permalink.html");
  const likes = Array.from(doc.querySelectorAll('[aria-label="Vind ik leuk"]'));
  assert.equal(likes.length, 14, "fixture changed — re-derive this test before trusting it");
  assert.equal(labelOf(findSaveButton(doc.body)), "Opslaan");
});

test("a lone-button section is not mistaken for an action bar", () => {
  // permalink.html's emoji picker sits in its own <section> with exactly one icon button.
  const doc = fixture("permalink.html");
  const sections = Array.from(doc.querySelectorAll("section"));
  const emojiSection = sections.find((s) => s.querySelector('[aria-label="Emoji"]'));
  assert.ok(emojiSection, "fixture changed — the emoji section is gone");
  assert.equal(findSaveButton(emojiSection), null, "one button is not a bar");
});

test("a profile-grid thumbnail has no action bar, and says so rather than guessing", () => {
  // The fallback contract: null means 'put it in the corner', never 'hide the button'.
  const doc = fixture("grid-thumb.html");
  assert.equal(doc.querySelectorAll("section").length, 0);
  assert.equal(findSaveButton(doc.body), null);
});

test("nested role=button wrappers do not make an inner element win", () => {
  // The real markup nests div[role=button] inside div[role=button]. Without the outermost
  // filter the last match is an inner wrapper, and the button would be positioned against
  // the wrong box.
  const doc = fixture("feed-post.html");
  const found = findSaveButton(doc.body);
  const parentIsAlsoButton = found.parentElement?.getAttribute("role") === "button";
  assert.equal(parentIsAlsoButton, false, "resolved to an inner wrapper, not the button itself");
});

test("the button is placed to the left of Save and centred on it", () => {
  const { x, y } = saveAnchorPosition({ left: 900, top: 500, height: 24 }, 24, 8);
  assert.equal(x, 868, "24px button, 8px gap → 900 - 24 - 8");
  assert.equal(y, 500, "same height as the icon → same top");
});

test("a taller Save button still centres rather than aligning to its top", () => {
  const { y } = saveAnchorPosition({ left: 900, top: 500, height: 40 }, 24, 8);
  assert.equal(y, 508, "(40 - 24) / 2 = 8 below the icon's top");
});
