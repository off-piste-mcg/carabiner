import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { selectContainers } from "../src/containers.js";
import { slideIndexFromSearch, slideIndexFromContainer, grabUrlFor } from "../src/slideIndex.js";

const load = (name) =>
  new JSDOM(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8")).window.document;

/** The one container the real captured feed fixture yields — an <article> with 4 dots. */
const feedContainer = () => selectContainers(load("feed-post.html"))[0];

test("reads the active dot out of the REAL captured feed markup", () => {
  assert.equal(slideIndexFromContainer(feedContainer()), 1);
});

test("follows the active dot when it moves — this is the bug that shipped", () => {
  const container = feedContainer();
  // Selected by label, not by position: nothing guarantees the dots are in document order.
  container.querySelector('button[aria-current="step"]').removeAttribute("aria-current");
  container.querySelector('button[aria-label="Go to slide 3"]').setAttribute("aria-current", "step");
  assert.equal(slideIndexFromContainer(container), 3);
});

test("no dots at all is no opinion, not slide 1", () => {
  const doc = new JSDOM(`<!doctype html><body><article><a href="/p/C1a2b3c4/">x</a></article>`).window.document;
  assert.equal(slideIndexFromContainer(doc.querySelector("article")), null);
});

test("two active dots is no opinion — we do not understand the page", () => {
  const doc = new JSDOM(`<!doctype html><body><article>
      <button aria-current="step" aria-label="Go to slide 1"></button>
      <button aria-current="step" aria-label="Go to slide 2"></button>
    </article>`).window.document;
  assert.equal(slideIndexFromContainer(doc.querySelector("article")), null);
});

test("grid tiles have no slide opinion", () => {
  for (const tile of selectContainers(load("grid-thumb.html"))) {
    assert.equal(slideIndexFromContainer(tile), null);
  }
});

test("never throws on junk input", () => {
  assert.equal(slideIndexFromContainer(null), null);
  assert.equal(slideIndexFromContainer(undefined), null);
  assert.equal(slideIndexFromContainer({}), null);
});

test("parses img_index out of a search string", () => {
  assert.equal(slideIndexFromSearch("?img_index=4"), 4);
  assert.equal(slideIndexFromSearch("?utm=x&img_index=12"), 12);
  assert.equal(slideIndexFromSearch("?img_index=1"), 1);
});

test("rejects img_index values that are not positive integers", () => {
  for (const s of ["?img_index=0", "?img_index=-2", "?img_index=abc", "?img_index=", "?img_index=1.5",
                   "?other=3", "", null, undefined, 7]) {
    assert.equal(slideIndexFromSearch(s), null, `expected null for ${JSON.stringify(s)}`);
  }
});

test("grabUrlFor: the address bar wins over the DOM", () => {
  assert.equal(
    grabUrlFor("https://www.instagram.com/p/C1a2b3c4/", { search: "?img_index=4", container: feedContainer() }),
    "https://www.instagram.com/p/C1a2b3c4/?img_index=4");
});

test("grabUrlFor: falls back to the container when the URL says nothing", () => {
  assert.equal(
    grabUrlFor("https://www.instagram.com/p/C1a2b3c4/", { search: "", container: feedContainer() }),
    "https://www.instagram.com/p/C1a2b3c4/?img_index=1");
});

test("grabUrlFor: knowing nothing returns the bare permalink, exactly as today", () => {
  assert.equal(grabUrlFor("https://www.instagram.com/p/C1a2b3c4/", {}),
               "https://www.instagram.com/p/C1a2b3c4/");
  assert.equal(grabUrlFor("https://www.instagram.com/p/C1a2b3c4/"),
               "https://www.instagram.com/p/C1a2b3c4/");
});
