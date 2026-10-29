# Auction Draft — spec

**Status: decided, not built.** It targets the 2027 preseason draft. It is held back from
the 2026 season because it changes a competitive rule (§5), and §16 fixes those once a
season's draft has started. Nothing in the code refers to it yet.

**Before building, re-check what this spec names.** It describes the code as it stood on
15 October 2026. Function names, file paths and the next migration number may have moved
since. The convention sections of CLAUDE.md win wherever the two disagree.

## What owners asked for

An auction on draft night, so the price of a team is set by the room and not only by the
poll. It was a feature request after the 2026 draft.

## Decided (Trevor, 15 October 2026)

- **Two stages.** First, the Top 25 are sold by live auction. Then snake rounds hand out the
  free (unranked) teams, exactly as the draft does today.
- **Who nominates.** The draft's existing snake order decides whose turn it is (1 → N, then
  N → 1, and so on). The nominator picks **any** unowned ranked team. They do not have to
  take the next team by rank.
- **Nominating is an opening bid at Market Value.** If nobody else bids, the nominator buys
  the team at Market Value. They cannot withdraw it.
- **A 30-second clock, reset by every bid.** Bids rise in **$1.00** steps. Any amount at
  least $1.00 above the high bid is accepted, so an owner can jump.
- **Skipped turns.** A nominating turn is skipped for an owner at the team cap, and for an
  owner who can't afford any remaining ranked team at Market Value under §11's reserve.
  Forcing them to nominate would force a purchase they can't make.
- **The auction ends** when every ranked team is sold, or when every eligible owner passes
  in a row. Any ranked team still unsold stays with the House and goes to §7's blind
  auction at the first market opening.
- **Unranked teams are never auctioned.** This is the same reason §7 refuses an unranked
  bid: at a $0.00 floor, a penny bid clears.
- **The format is a league setting.** It is `snake` or `auction`, defaults to `snake`, and
  locks when the draft starts. A group can still choose the quicker draft, and existing
  leagues don't change.

The 30-second clock and the $1.00 step are constants, not settings. Each extra setting is a
dial that can contradict §5, and nobody has asked to tune these. Add one only when a league
asks for it.

## The rule text (§5), for Spencer to approve

Write this first, before any code. It is a v1.x Version History row, effective from the
2027 draft.

- **Draft Format** describes both formats. Under auction, it describes the two stages, the
  snake nominating order, the 30-second clock and the $1.00 step.
- **Draft Prices**: under auction, a ranked team's Market Value is its **opening bid**, not
  its price. The winning bid is what the owner pays and what the House receives.
- The nominator's forced purchase at Market Value, and what happens to a ranked team nobody
  buys.
- `public/how-to-play/` gets its summary updated in the same change.
  `ConventionsTest::testTheGuideStaysSubordinateToTheRulebook` requires every figure it
  publishes to appear in the rulebook.

## What it changes about the economy

- **The House can open above $350.** Premiums paid on draft night go into the House, so
  the Prize Pool grows (§10, §12). That is arguably the point of the auction.
- **The buy-in floor becomes a lower bound.** `minimum_buy_in_cents()` assumes Market Value
  prices. Under auction it is still the least a league needs, so the Desk's warning stays
  correct, but its wording should say "at least".
- **§11's reserve caps every bid.** Nobody can bid their way into Margin Call on draft
  night. This is the same check that already binds a draft pick.

## Design

### Schema (`setup/schema.sql` plus a migration)

Every change is additive.

- `drafts.stage ENUM('auction','snake') NULL`. It is set when the draft starts and flipped
  once, under the draft lock. It belongs to a single draft and has one writer, so it is not
  the stored season `phase` CLAUDE.md warns against.
- `draft_lots`:
  - `id, draft_id, team_id, nominated_by, high_bid_cents, high_owner_id, closes_at,
    status ENUM('open','sold','void','undone'), pick_id, created_at`.
  - At most one open lot per draft is enforced by a UNIQUE key on a `STORED` marker column
    generated from `status` alone (the `uq_one_open_draft` pattern).
  - `closes_at` is written as `NOW() + INTERVAL 30 SECOND` and only ever compared in SQL. It
    is on **MySQL's clock**, so it needs a one-line constraint comment.
- `draft_bids (id, lot_id, owner_id, amount_cents, created_at)`. The nomination writes the
  first row. This is the only record of a bid that was outbid.
- Every new datetime column gets an entry in `PP_REPLAY_COLUMNS` (all `mysql_epoch`).
  `ReplayShiftTest` fails until each is classified.

### Setting

`PP_LEAGUE_SETTINGS['draft_format']`: type `choice`, choices `snake`/`auction`, default
`snake`, group `rules`, `locks => 'draft_start'`.

### Pure deciders (`lib/game/draft_auction.php`)

This is a new file. `lib/game/auction.php` is already §7's blind auction.

- `decide_auction_nomination($snap, $teamId)`. It refuses when:
  - it is not this owner's turn, the stage is not `auction`, or a lot is already open;
  - the team is owned, or is unranked;
  - the reserve check fails with `cash_out` = Market Value.
- `decide_auction_bid($snap, $amountCents)`. It refuses when:
  - the lot is not open, or `seconds_left <= 0`;
  - `amount < high + step`;
  - the bidder already holds the high bid;
  - the bidder is at the cap;
  - the reserve check fails with `cash_out` = amount and `teams_gained = 1`.
- `decide_auction_nominator_skip($snap)`: whether this owner's turn is skipped.
- The reserve goes through `decide_reserve_headroom()`, the same call a draft pick makes.
  `seconds_left` is computed in SQL (`TIMESTAMPDIFF(SECOND, NOW(), closes_at)`), so no PHP
  clock touches it.

### Wiring (`lib/draft.php`, `lib/actions/draft.php`)

- **A sale goes through `draft_apply_pick()` with the winning price passed in.** This keeps
  one route for granting a team, so `ck_team_basis`, the reserve check, the ledgers and
  `ConventionsTest`'s derived list of grant routes all stay unchanged.
- **A new `draft_close_due_lot` closes a lot on read.** No job runs the clock. The first request
  to see an expired lot does the following:
  1. Locks the draft row first.
  2. Re-reads the open lot `WHERE closes_at <= NOW()`.
  3. Buys the team for the high bidder at the high bid.
  4. Marks the lot sold with `AND status='open'` in the `WHERE` and requires
     `rowCount() === 1`.
  5. Advances to the next nominator.

  A second close is a no-op. It is called at the top of every draft action and of
  `draft_state`.
- **This needs your agreement before it's built:** `draft_state` is a GET, and it would now
  move money. `catch_up_league()` already does the same on page loads. The close is
  idempotent and serialised by the lock, so I'd keep the GET and add a line to the comment
  over `$getOk` in `api.php`. The alternative is a POST `draft_tick` sent from the poll.
- **Advancing.** During the auction stage, `draft_advance()` skips owners according to the
  skip rule. When the auction ends, it switches the stage to `snake`, resets the round and
  position to 1/1, and clears the passes.
- **New actions**, each with a line in `api.php`'s `$map` and a `case`, both POST with CSRF:
  - `draft_nominate {team_id}`
  - `draft_bid {lot_id, amount}`. Carrying `lot_id` means a bid placed against a lot that
    has since closed is refused, rather than landing on the next lot.
- **`draft_pass`** passes a nominating turn during the auction stage.
- **`undo_pick`** undoing a sold lot reverses it through the existing path and marks the lot
  `undone`. Undo is refused while a lot is open.

### Draft Room

- **Auction stage, an owner's turn.** Each unowned ranked team shows **Nominate** with its
  opening price. Unranked teams stay hidden until the snake stage.
- **Open lot panel:** the team, the high bid and bidder, and a countdown; **Bid $X** (the
  next minimum) plus an amount field for jumps. The nominator sees that they are buying at
  $X unless outbid.
- **Gated controls.** A capped owner, or one whose bid the reserve would refuse, keeps the
  control with a `gate_tag()` reason. The control is never removed.
- **Polling.** Poll every **1 second while a lot is open**, and every 3 seconds otherwise.
  This stretches the Draft Room's existing polling exception, so CLAUDE.md's paragraph on it
  needs a sentence. The countdown starts each render from the server's `seconds_left`, and a
  reload on any `version` change corrects it.
- Control labels are in Title Case: *Nominate*, *Bid $27.00*, *Pass*.

## Tests (each verified by breaking the code on purpose)

- **Unit, `DraftAuctionDecisionTest`:**
  - minimum bid, including the boundary at exactly high + $1.00;
  - self-raise, cap and reserve refusals (the reserve case with headroom one cent short);
  - a closed lot refused at `seconds_left = 0`;
  - an unranked or owned team can't be nominated, nor one the owner can't afford;
  - the skip rule.
- **Integration, `DraftAuctionTest`**, through real actions:
  - nominate, outbid, then close (with `closes_at` forced into the past on MySQL's clock):
    the winner pays the bid, the House receives it, and the basis equals the bid;
  - the forced purchase at Market Value;
  - a second close is a no-op;
  - a stale `lot_id` is refused;
  - the switch to snake, with unranked picks still free;
  - an unsold ranked team stays with the House;
  - undo refunds the lot;
  - the ledger reconciles throughout.
- **Rules:** §5's published figures asserted literally (30 seconds, $1.00, opening at Market
  Value, the forced purchase).
- **Journey:** an auction-format `DraftNightTest` variant, asserting conservation (the House
  equals the sum of winning bids) rather than any particular price.
- **Mutations worth recording:**
  - `<` to `<=` on the minimum bid;
  - remove the self-raise check;
  - skip the reserve in the bid decider;
  - remove `AND status='open'` from the close;
  - close on PHP's `time()` instead of SQL's `NOW()`.

## Build order

1. Rule text, for Spencer to approve.
2. Schema and migration.
3. Deciders, with their unit tests.
4. Wiring and actions, with integration tests.
5. Draft Room.
6. Rules and Journey tests.
7. Docs.

Ship it after the 2026 season settles and before the 2027 draft is scheduled, so a league
can try it in a test draft first. A `setup/scenarios/` fixture of a league sitting in
`setup` with the auction format chosen would make that one click.

## Out of scope

- An auction policy in `setup/simulator.php`. The simulator stays on snake.
- Replay fixtures, which draft snake.
- Golf. This machinery is what a golf draft would reuse.

Delete this file when the auction draft ships. From then on the code and the rulebook are
the record.
