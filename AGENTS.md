# AGENTS.md

Instructions for any coding agent working in this repository, and for the people working
beside one. Claude Code reads it through `CLAUDE.md`; other tools read it by this name.

## What this is

A port of **Sharps Pick 'Em** from PHP to Erlang/OTP, and the start of a multi-sport
version of it. The game is college football team ownership: owners buy, sell, trade and bid
on FBS teams priced by the weekly polls, all money flows through a communal House Account,
and the House pays the playoff prize pool back out. It is a **ledger, not a payment
processor** — real money is settled in person.

The PHP app keeps running the live 2026 season while this is built. Nothing here deploys
until the go/no-go below says so.

## Where the answers live

| Question | Answer |
|---|---|
| What are the rules? | `reference/pp26dev/public/rules/index.html` — the rulebook, and the ONLY source of truth for the rules until this app publishes its own. `public/how-to-play/` is its summary for new owners |
| What exact arithmetic does the PHP use? | `reference/pp26dev/lib/game/` — the pure deciders, the only PHP code kept |
| What does it look like? | `reference/pp26dev/public/assets/style.css`, each component's `index.css`, the logos and icons |
| What does a league hold? | `reference/pp26dev/setup/schema.sql` — the data model, as a list of what is recorded, not a design to copy |
| What seasons can we replay? | `reference/pp26dev/setup/fixtures/` — 2022 to 2025 from CFBD, kickoffs and lines included |
| Which features exist? | `reference/pp26dev/docs/OVERVIEW.md` — the pages, actions and game loops to cover |
| What must the Erlang reproduce exactly? | `golden/`, once recorded — see *The oracle* |
| What is decided but not built? | `reference/pp26dev/docs/AUCTION-DRAFT.md` — build it here, not in the PHP |

### `reference/` is frozen

`reference/pp26dev/` holds selected files from the PHP app at commit
`b13448405413f1f16ae0f88676d47bbb5fc851ff` of the pp26dev repository, at their original
paths: the rulebook, the visual design, the data model, the cached seasons and the pure
deciders. The PHP's wiring — its locks, transactions, cron, pages and markup — is left out
on purpose, because this port replaces it rather than translating it. If a question needs
another file, read it in the pp26dev repository at that commit.

It is here to be READ. **Never edit it**: a snapshot that someone corrects becomes a second
source of truth that agrees with neither. If the live PHP changes a rule, re-snapshot at
the new commit and update the hash above in the same commit. Delete `reference/` when the
port ships.

## The code carries its own explanation

**There are no comments in this codebase.** Not shortened ones, not explanatory ones.
A test fails the build on any comment token (`erl_scan:string/3` with
`return_comments`). Explanation lives in:

- **names** — functions, atoms, record fields and variables that say what they are.
  No `State1`/`State2`/`NewState`: name each by what happened to it (`AfterStakeDebit`),
  or extract the step into a named function. No `S`, `St`, `Acc`, `X`.
- **function heads and guards** — a decider reads top to bottom as a decision table, one
  clause per case.
- **tagged results** — `{refused, already_high_bidder}`, not `{error, 3}` or a string.
  A refusal's human sentence is rendered at the edge, from the atom.
- **types** — `-spec` and `-type` on every exported function; Dialyzer runs in CI.
- **attributes** for what a name cannot carry and a reader must know:
  `-rule("§11").` cites the rulebook section a module implements, and
  `-ruled_by(spencer).` says who may change it. Both are data, readable through
  `module_info(attributes)`, so a test can check every cited section is covered.
- **test names** — a mutation a test exists to catch goes in its name or its EUnit
  description string.

`-doc` and `-moduledoc` are banned with `%`. Rationale and history belong in commit
messages.

## The game core

- **Pure deciders, then effects.** Each rule is a pure function from a snapshot and an
  input to effects or a refusal — no process, no I/O, no clock read. The league process
  gathers the snapshot, calls the decider and applies the effects.
- **One process per league.** It serialises everything that league does, which is what
  replaces the PHP's row locks and lock ordering. Timers in the process replace cron and
  the PHP's catch-up-on-page-load.
- **The ledger is an append-only event log.** An event is persisted before the caller gets
  a reply. All state is a fold over the events. The PHP's
  `check_ledger_invariants()` becomes a fold too, run after every event in tests and
  replays.
- **Money is integer units.** Each league declares what a unit is (cents for football).
  No floats, ever. One parser; formatting only at the edge. Field names say `units`, not
  `cents`.
- **Time is tagged.** `{utc, Seconds}` and `{league_local, DateTime}` are different types,
  and a function takes one or the other. The PHP lost hours to reading a column on the
  wrong clock; here that is a `function_clause` error or a Dialyzer failure.
- **Derive on read; never store a phase.** The season's moments are moved by different
  authorities (the Commissioner, the poll feed, the schedule), so no single stored value
  can track them.
- **Football is the first ruleset, not the kernel.** Keep sport-specific rules in their
  own modules so the seam is easy to cut, but do not design a sport-agnostic behaviour
  until a second sport (golf) exists to test it against.

## The front end

- **Static, semantic HTML pages.** Headings, tables, forms, labels and empty states are
  written in the files. Links and forms work before any script runs.
- **Native custom elements, no framework, no build step.** ES modules loaded directly.
- **The custom element tag is the component boundary.** Classes only where a boundary
  cannot be a tag. CSS selectors follow the markup's element hierarchy, nested from the
  tag, with `>` so a rule never reaches into a nested component and `:where()` where a
  long selector would otherwise build up specificity.
- **State reaches CSS through attributes and custom properties.** Discrete state uses the
  attribute the platform already has (`aria-busy`, `aria-current`, `aria-invalid`,
  `:disabled`, `[open]`, `:user-invalid`, `:has()`), whose selectors set custom
  properties. Continuous state (a countdown) is written by JS straight into a custom
  property with `style.setProperty`. Interaction starts from `<a>`, `<form>` and
  `<button>`.
- **Data goes in through `<template>` and `textContent`. Never `innerHTML`.**
- **Strict CSP**: no `'unsafe-inline'` in `script-src` or `style-src`.
- **The visual design is the PHP app's, unchanged** — the `:root` tokens, fonts, pixel
  borders, hard shadows and scanlines in `reference/pp26dev/public/assets/style.css` and
  each component's `index.css`. Port the look exactly; only the selectors change.
- Control labels are Title Case. Money renders in the mono font.

## The API

- Authenticated JSON. The session is an `HttpOnly`, `Secure`, `SameSite` cookie on the
  same origin, plus a CSRF header on every mutation. No tokens in `localStorage`.
- A mutation is a POST. Only a read may be a GET.
- State is fetched **at a version** — `/api/state/<version>` — never "current". A page
  carries the SHA-256 `integrity` of the state it expects and `fetch()` verifies it. The
  response at a version never changes, so it can be cached forever. Later the page carries
  the signed head of the league's transparency log, and the state carries a proof that it
  belongs to it.
- Live views subscribe to server-sent events from the league process instead of polling.

## The oracle

`golden/` will hold recorded `{decider, inputs, expected output}` cases, captured from the
PHP replaying the cached 2022–2025 seasons (`reference/pp26dev/setup/fixtures/`). Each
file records the pp26dev commit it came from. Recording needs the PHP and MySQL running,
so it is done on the PHP box and the JSON copied here. The Erlang must reproduce every case
exactly; a disagreement is a bug in one or the other, and the rulebook decides which.

## Testing

- **Break the code to check the test.** A test proves nothing until it has failed for the
  reason it exists. Re-introduce the bug, run it, put the code back.
- **One rule, one test.** The decider that owns an arithmetic tests it exhaustively; its
  callers test only that they delegate.
- **Pin what the rulebook publishes, literally.** §11 says $9.00 to the winner, so assert
  900, not a figure computed from the same constant the code uses.
- **Replays are the integration test.** Whole cached seasons played through the league
  process, with the ledger invariants checked after every event.

## The plan

1. Scaffold: rebar3 project, Dialyzer, the no-comments test passing on an empty project.
2. Record `golden/` from the PHP.
3. Port `reference/pp26dev/lib/game/` decider by decider, each against its golden cases.
   Start with the Battle result (§11).
4. The league process and event log; replay all four seasons with ledgers identical to the
   PHP's.
5. **Go/no-go, around April 2027.** If step 4 holds, shadow it and cut over for the 2027
   season. If not, the PHP runs another year and nothing is lost. A cutover can only happen
   between the end of the CFP in January and the 2027 draft in late August.
6. Then: feeds and timers, the Rules and Journey tests, the web layer, the transparency log.

## Commits

Small and explained in the message. Co-author trailers go Trevor first, then the agent:

```
Co-Authored-By: Trevor Plassman <trevor@brasstacksweb.com>
```
