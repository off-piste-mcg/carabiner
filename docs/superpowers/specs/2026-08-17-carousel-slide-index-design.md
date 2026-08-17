# The in-page button must grab the slide you are looking at — design

**Date:** 2026-08-17 · **Status:** approved, not yet implemented
**Branch:** `feat/browser-extension`

## The defect

Found 2026-08-17 by a user test of checklist item 10, not by any test in the repo: on the
Instagram feed, swipe a carousel to slide 2, click the Carabiner button, answer the dialog
with **"This slide"** — and slide **1** lands in `~/Downloads`. The button reports success.
Nothing anywhere says the wrong file was saved.

The cause is one line of omission. `shortcode.js`'s `permalinkFromHref` canonicalises every
match to a bare `https://www.instagram.com/p/CODE/`, deliberately stripping the handle
prefix a profile grid adds. It also drops any slide information, because there never was
any: the href it reads is a link to the *post*, not to a slide. The app then behaves
exactly as documented — gotcha #15: absent `img_index` means slide 1 — so "this slide"
resolves to the first one, always.

This is worse than an ordinary bug in one specific way, which is why it is worth a spec
rather than a quick patch: **the failure is silent and plausible.** A user who swipes to
slide 4 and gets slide 1 sees a green tick, a banner, and a real file. On a post whose
slides look alike, they may not notice at all.

Scope note: the **hotkey** path does not have this bug. It reads the front tab's URL, and
on a permalink page Instagram writes `?img_index=N` into the address bar itself. Only the
extension discards the information.

## Evidence

Measured against the captured real fixtures in `extension/test/fixtures/` — not synthetic
markup, per gotcha #31 — by driving `containers.js`'s own `selectContainers` over each:

| Fixture | Container | `Go to slide` dots inside | `aria-current="step"` inside |
|---|---|---|---|
| `feed-post.html` | `<article>` | 4 | **1** → `"Go to slide 1"` |
| `permalink.html` | `<article>` | 0 | 0 |
| `grid-thumb.html` | 12 × `<a>` | 0 | 0 |

Two things follow. First, Instagram marks the active carousel dot **semantically**, with
`aria-current="step"` on a `<button aria-label="Go to slide N">`, and those dots sit
**inside** the very container the button is already keyed on. The signal we need is in
reach and is an ARIA attribute rather than an obfuscated class name, so it is among the
more durable things Instagram emits.

Second — and this is a gap, stated rather than papered over — **`permalink.html` is not a
carousel.** It contains no dots, no `Next`, no `Previous`. So we have *no captured markup
of a permalink-page carousel*, and this design deliberately does not depend on any
assumption about one (see "Precedence" below). Capturing that fixture is worthwhile
follow-up work; it is not a blocker.

## Decisions

**Resolve the index at click time, never at attach time.** `content.js` closes `url` over
in `makeButton`, and the buttons map (`container -> { host, url, place }`) rebinds only
when `url` changes. Baking a slide index into `url` would therefore destroy and recreate
the button on every swipe — and resolving at attach time would send whatever slide was
showing when the button first appeared. Neither is acceptable; the click handler is the
only place where "which slide is showing" is a question with a current answer.

**The address bar wins over the DOM.** Where a page URL already names a slide, that is the
value the app has always trusted and the value the hotkey path feeds it. The DOM is
consulted only when the URL names nothing — which is every feed post, since a feed URL is
just `instagram.com/`. This ordering also means the missing permalink-carousel fixture
cannot hurt us: on a permalink page the answer comes from `location.search` regardless of
what the dots do or do not do there.

**Unknown means today's behaviour, silently** (decided by Wisse, 2026-08-17). If a post is
a carousel but no single active dot can be found — Instagram changed the markup — the
extension sends the bare permalink, exactly as it does now, plus a `console.debug`
breadcrumb. Rejected alternatives: plumbing an "index unknown" flag through `GrabServer`
into the shared `carabiner` script so the dialog could relabel "This slide" as "First
slide" (touches the Shortcut's dialog too, for a case that only arises on markup churn);
and grabbing all slides when unknown (never wrong, but overrides an explicit user choice
in the other direction). The fixture tests are what will catch the churn.

## Design

One new pure module, `extension/src/slideIndex.js`, in the same style and with the same
contract as `shortcode.js`: **it must never throw**, and `null` means "no opinion", never
"slide 1".

```
slideIndexFromSearch(search)      -> positive integer | null
slideIndexFromContainer(element)  -> positive integer | null
grabUrlFor(permalink, { search, container }) -> string
```

- `slideIndexFromSearch` parses `img_index` out of a `location.search`-shaped string.
  Anything that is not a positive integer is `null`.
- `slideIndexFromContainer` queries `button[aria-current="step"]` **within the container**
  and parses `N` out of its `aria-label` (`Go to slide N`). It returns `null` unless
  **exactly one** dot is active — zero means not a carousel or markup churn, and more than
  one means we do not understand the page well enough to answer.
- `grabUrlFor` composes: search first, container second, and returns the bare permalink
  when both decline. It appends `?img_index=N` — the same shape Instagram itself writes,
  and the same shape the app already parses.

`content.js`'s click handler becomes `grabUrlFor(url, { search: location.search, container })`
and sends the result. Everything else is untouched: the buttons map keeps keying on the
**bare** permalink, so a swipe changes what a click *sends* without changing what the map
*holds*.

Per surface, the resulting behaviour: **feed** reads the dots; **permalink page** reads the
address bar; **profile grid** sends nothing extra (a grid tile shows the cover, so slide 1
is genuinely the right answer); **reel** sends nothing extra (single video).

**No server-side change is needed, and this is measured, not assumed.** `GrabGate` already
accepts a query string: a `POST /grab` carrying
`https://www.instagram.com/p/DSBAavTCpJo/?img_index=1` was accepted and completed a real
grab on 2026-08-17.

## Testing

Against the real fixture, never a hand-written one:

1. `feed-post.html`'s container resolves to **1** (its active dot is slide 1).
2. The same fixture, mutated so slide **3** carries `aria-current="step"`, resolves to 3 —
   this is the test that would have caught the original bug.
3. Zero active dots → `null`. Two active dots → `null`.
4. Grid tiles → `null`; the bare permalink is what gets sent.
5. `?img_index=4` beats a container whose active dot says 1 (precedence).
6. Junk in `img_index` (`0`, `-2`, `abc`, absent) → `null`, and nothing throws.
7. The dedup key is unaffected by the slide index — pinning that we did not bake it into
   `url`.

**Mutation-check the guard, do not trust it** (gotcha #34): revert the click-time
resolution to attach-time and confirm a test actually goes red, rather than assuming it
would.

## Out of scope

The post modal (`[role=dialog]`) carries no button by design (commit 8c59ddc), and Stories
are outside the extension's scope entirely. Neither is affected.

## Follow-up, not blocking

Capture a real **permalink-page carousel** fixture and add it to `extension/test/fixtures/`,
closing the evidence gap noted above. If such a page turns out to render dots, this design
already handles it — the address bar simply answers first.
