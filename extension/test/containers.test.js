import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { selectContainers } from "../src/containers.js";
import { permalinkFor } from "../src/shortcode.js";

// Fix round 1, Finding 1 (Important, DEMONSTRATED by the reviewer against these exact
// fixtures): the pre-fix selector `article, a[href^='/p/'], a[href^='/reel/']` matched
// BOTH an <article> and the permalink anchor nested inside it, so feed-post.html and
// permalink.html each produced 2 buttons instead of 1 — the second landing on the
// timestamp anchor. grid-thumb.html was already correct at 4 (four distinct posts, no
// <article> wrapper in that view). These tests pin the exact count per fixture so this
// can't silently regress.

const load = (name) =>
  new JSDOM(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8")).window.document;

test("feed-post.html: exactly one button, on the <article>, not the timestamp anchor", () => {
  const doc = load("feed-post.html");
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "ARTICLE");
  assert.match(permalinkFor(containers[0]), /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
});

test("permalink.html: exactly one button, on the <article>, not the timestamp anchor", () => {
  const doc = load("permalink.html");
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "ARTICLE");
  assert.match(permalinkFor(containers[0]), /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
});

test("grid-thumb.html: exactly four buttons — one per distinct post, none duplicated", () => {
  const doc = load("grid-thumb.html");
  const containers = selectContainers(doc);
  assert.equal(containers.length, 4);
  for (const el of containers) {
    assert.equal(el.tagName, "A");
    assert.match(permalinkFor(el), /^https:\/\/www\.instagram\.com\/(p|reel)\/[\w-]+\/$/);
  }
  // All four permalinks are distinct posts, not the same post counted twice.
  const links = containers.map(permalinkFor);
  assert.equal(new Set(links).size, 4);
});

test("an anchor nested inside an <article> is never selected on its own", () => {
  const doc = new JSDOM(
    `<!doctype html><body><article><a href="/p/C1a2b3c4/">permalink</a></article></body>`
  ).window.document;
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "ARTICLE");
});

test("a bare permalink anchor with no enclosing <article> is selected on its own", () => {
  const doc = new JSDOM(
    `<!doctype html><body><a href="/p/C1a2b3c4/">permalink</a></body>`
  ).window.document;
  const containers = selectContainers(doc);
  assert.equal(containers.length, 1);
  assert.equal(containers[0].tagName, "A");
});
