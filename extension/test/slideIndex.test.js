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

test("the label is read in ANY language — Instagram localizes aria-label", () => {
  // Final review, Finding 2: requiring the literal English word "slide" meant a Dutch or
  // Spanish Instagram UI parsed as null, i.e. a silent revert to the original slide-1 bug
  // for every non-English user. `aria-current="step"` is language-neutral; the label read
  // must be too, so parse the first integer anywhere in it.
  const labels = ["Ga naar dia 3", "Ir a la diapositiva 3", "スライド3に移動", "Перейти к слайду 3"];
  for (const label of labels) {
    const container = feedContainer();
    container.querySelector('button[aria-current="step"]').setAttribute("aria-label", label);
    assert.equal(slideIndexFromContainer(container), 3, `expected 3 from ${JSON.stringify(label)}`);
  }
});

test("a 'N of M' label reads N, not M", () => {
  const container = feedContainer();
  container.querySelector('button[aria-current="step"]').setAttribute("aria-label", "Go to slide 3 of 4");
  assert.equal(slideIndexFromContainer(container), 3);
});

test("a label with no number at all is still no opinion, never slide 1", () => {
  const container = feedContainer();
  container.querySelector('button[aria-current="step"]').setAttribute("aria-label", "Volgende");
  assert.equal(slideIndexFromContainer(container), null);
  const bare = feedContainer();
  bare.querySelector('button[aria-current="step"]').removeAttribute("aria-label");
  assert.equal(slideIndexFromContainer(bare), null);
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

/** The post the real captured feed fixture is actually about. */
const FEED_PERMALINK = "https://www.instagram.com/p/Db-Xe7jDlkM/";

test("grabUrlFor: the address bar wins over the DOM — when it is the SAME post", () => {
  // `pagePermalink` is what the page's own path resolves to. Equal to the container's
  // permalink ⇒ the address bar is talking about this post ⇒ it wins, as it always has.
  assert.equal(
    grabUrlFor("https://www.instagram.com/p/C1a2b3c4/", {
      search: "?img_index=4",
      pagePermalink: "https://www.instagram.com/p/C1a2b3c4/",
      container: feedContainer(),
    }),
    "https://www.instagram.com/p/C1a2b3c4/?img_index=4");
});

test("grabUrlFor: a page URL naming a DIFFERENT post never lends its slide index", () => {
  // Final review, Finding 1: opening a post modal pushes /p/A/?img_index=3, but the feed
  // containers BEHIND the modal keep their buttons. Clicking one used to send B at A's
  // slide — a silent wrong file. The dots inside B are per-container and correct, so the
  // right answer here is B's own active dot (slide 1 in the real fixture), never 3.
  assert.equal(
    grabUrlFor(FEED_PERMALINK, {
      search: "?img_index=3",
      pagePermalink: "https://www.instagram.com/p/AAAAAAAAAA/",
      container: feedContainer(),
    }),
    `${FEED_PERMALINK}?img_index=1`);
});

test("grabUrlFor: with no page permalink at all the address bar is not trusted", () => {
  // A feed URL ("/") resolves to no permalink, so nothing corroborates the query string.
  // Falling through to the container is the safe direction: those dots are per-container.
  assert.equal(
    grabUrlFor(FEED_PERMALINK, { search: "?img_index=3", container: feedContainer() }),
    `${FEED_PERMALINK}?img_index=1`);
  // …and with no container to fall back on, it is simply "no opinion".
  assert.equal(
    grabUrlFor(FEED_PERMALINK, { search: "?img_index=3" }), FEED_PERMALINK);
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
