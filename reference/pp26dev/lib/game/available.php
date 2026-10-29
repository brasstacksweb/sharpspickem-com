<?php

// What may be done with this team right now? (§6, and §15 defines the words)
//
// TWO questions, asked per team, because they protect different things (Q18):
//
//   AVAILABLE — may it be bought, sold, added or dropped WITH THE HOUSE? Those pay
//               published Market Value, so they need a price that can still be trusted.
//   TRADABLE  — may two owners trade it (§9)? The owners set their own price, so the
//               pricing rule does not apply at all.
//
// THREE CLAUSES:
//
//   (a) PRICED — nothing has been played since the last market OPENING, which is a day
//       after the poll. Clearing at the POLL instead leaves a window in which a team is
//       buyable outright while other owners' sealed bids for it are still queued, and §7
//       promises a bid buys certainty over "a team you cannot simply take now".
//
//       IT IS ABOUT THE WEEK, NOT ONLY THIS TEAM: Market Value is a rank, so a team on a
//       bye is repriced by everyone else's results. Across 2024 and 2025, 70% of
//       ranked-and-idle team-weeks moved on the next poll, the largest by $17.00.
//
//       THE TRIGGER IS THE WEEK'S LAST KICKOFF, NOT ITS FIRST. First-kickoff locking is
//       stricter and takes availability to roughly ZERO, because weeks 7–14 open with
//       Tuesday MACtion and the opening is the following Monday.
//
//       IT CANNOT BE DECIDED BY COMPARING WEEK NUMBERS — the AP poll labelled week 2 is
//       released before a week-1 Labour Day game. Only the times can answer it.
//
//   (b) NOT GAME-LOCKED — from $lead before kickoff until the game is officially FINAL.
//       The ONLY clause that applies to a trade, and it applies all season including the
//       playoff (Q18 removed the postseason freeze).
//
//       "Officially final" is CFBD's `completed` flag, bounded by PP_GAME_MAX_SECONDS: a
//       game CFBD never marks complete would otherwise lock the team FOR EVER, and clause
//       (a) still holds the House side shut until the opening prices it.
//
//   (c) NOT CARRYING A LIVE BATTLE — §11. The owner on the other side is entitled to face
//       the team they were matched against, and this is what stops an owner selling their
//       way out of a Battle they expect to lose.
//
// MEASURED over the real 2024 and 2025 FBS schedules, as a share of the in-season clock
// from a week's first kickoff to the opening that prices it — re-derive it that way or the
// figures will not line up:
//
//     clearing at the poll, this team only      71.8%  /  70.9%
//     clearing at the OPENING, this team only   61.3%  /  60.3%
//     …and the whole board with the week        54.0%  /  53.0%   (the rule as it stands)
//     …locking from the week's FIRST kickoff    ~0%    /  ~0%     (measured, rejected)
//
// Rule (b) costs 0.22%; (a) does essentially all the work, which is why TRADABLE is so much
// wider than AVAILABLE. Nothing is REFUSED by any of it — an unavailable team's order
// queues and settles at the opening (§6).
//
// DERIVED, NOT STORED: a 30-minute rule cannot be delivered by an hourly job, and there is
// no column to forget to clear.
//
// THE CLOCKS MEET ONLY AT THE EDGES — everything here is unix timestamps. `priced_at` comes
// from `poll_cycles.applied_at` through SQL's UNIX_TIMESTAMP() (MySQL's clock); `start`
// from `games.kickoff_at` through strtotime() (PHP/UTC). Converting either inside the rule
// is the four-hour bug.
//
// Pure: no db(), no clock, no network. The caller supplies all four.
//
// $snapshot: [
//   'teams'     => [ ['id'=>int, 'name'=>string, 'has_live_battle'=>bool], … ],
//   'priced_at' => ?int,   -- when the current poll cycle was applied. NULL = no poll yet.
//   'now'       => int,    -- unix now
//   'lead'      => int,    -- seconds before kickoff a team comes off the board
// ]
// $input: [ 'games' => [ ['home'=>string,'away'=>string,'start'=>?int,'completed'=>bool], … ] ]
//
// Returns [ 'teams' => [ team_id => ['available'=>bool,'why'=>?string,
//                                    'tradable'=>bool,'why_trade'=>?string], … ] ]

const PP_UNAVAILABLE_REASONS = [
    // COVERS BOTH HALVES of §6's first rule, which is why it does not say "its result":
    // a team on a bye has no result of its own and is off the board all the same.
    'unpriced' => 'this week\'s results have not been priced yet',
    'kickoff'  => 'it plays within the next 30 minutes',
    'in_game'  => 'its game is in progress',
    'battle'   => 'it is carrying a live Battle',
    // "no poll has PRICED", never "there is no poll" and never "the market is shut". The
    // condition is that no OPENING carrying one has settled, and a league can have a poll
    // applied and still be here — the rest of the board stays fully tradable.
    'no_opening' => 'no poll has priced this week\'s results yet',
];

/**
 * How long after kickoff a game is still assumed to be running when CFBD has not marked it
 * complete — longer than any real game, short enough not to strand the team. See rule (b).
 */
const PP_GAME_MAX_SECONDS = 8 * 3600;

/**
 * Where a game is: `upcoming`, `live` or `final`. ONE definition, shared by the schedule and
 * the Battle cards, so the two surfaces cannot disagree about the same kickoff.
 *
 * A game past the bound with no `completed` flag reads FINAL rather than live.
 */
function game_state(?int $start, bool $completed, int $now): string
{
    if ($start === null || $start > $now) {
        return 'upcoming';
    }
    if (!$completed && $now - $start < PP_GAME_MAX_SECONDS) {
        return 'live';
    }
    return 'final';
}

function decide_availability(array $snapshot, array $input): array
{
    $openedAt = $snapshot['opened_at'] ?? null;
    $now      = (int) $snapshot['now'];
    $lead     = (int) $snapshot['lead'];

    // Indexed by lowercased team name. Never a column-to-column join: `games` and
    // `teams.name` carry collations MySQL refuses to compare.
    $last   = [];    // name => latest kickoff already past
    $next   = [];    // name => earliest kickoff still ahead
    $inGame = [];    // name => a game has started and is not final yet

    // THE WHOLE BOARD GOES STALE WITH THE WEEK's LAST KICKOFF, not only the teams that
    // played — see clause (a) in the header.
    $startedAt   = 0;      // the latest kickoff that has happened
    $startedWeek = null;   // …and the week it belongs to
    $aheadWeek   = null;   // the earliest week still to be played
    foreach ($input['games'] as $g) {
        $st = $g['start'] ?? null;
        if ($st === null) {
            continue;
        }
        // REGULAR SEASON ONLY for the week arithmetic: the POSTSEASON RESTARTS THE
        // NUMBERING AT 1, so a first-round playoff game reads as "week 1 still ahead" and
        // the whole-board half below never fires. The kickoff lock still reads every game.
        if (($g['season_type'] ?? 'regular') !== 'regular') {
            continue;
        }
        $w = isset($g['week']) ? (int) $g['week'] : null;
        if ((int) $st <= $now) {
            if ((int) $st > $startedAt) {
                $startedAt = (int) $st;
                $startedWeek = $w;
            }
        } elseif ($w !== null && ($aheadWeek === null || $w < $aheadWeek)) {
            $aheadWeek = $w;
        }
    }
    // The week is DONE when every game filed under the week of the most recent kickoff has
    // started; one still ahead in that week means the slate is mid-flight.
    $boardStaleSince = ($startedAt > 0 && $startedWeek !== null
        && ($aheadWeek === null || $aheadWeek > $startedWeek)) ? $startedAt : null;

    foreach ($input['games'] as $g) {
        $start = $g['start'] ?? null;
        if ($start === null) {
            // An undated game is unscheduled, so it cannot be imminent — skipping is the
            // correct answer rather than the cautious one.
            continue;
        }
        $start = (int) $start;
        foreach ([$g['home'], $g['away']] as $side) {
            $k = strtolower((string) $side);
            if ($start <= $now) {
                if (!isset($last[$k]) || $start > $last[$k]) {
                    $last[$k] = $start;
                }
                // The same test the cards draw, so §6 and the schedule cannot disagree.
                if (game_state($start, !empty($g['completed']), $now) === 'live') {
                    $inGame[$k] = true;
                }
            } else {
                if (!isset($next[$k]) || $start < $next[$k]) {
                    $next[$k] = $start;
                }
            }
        }
    }

    $out = [];
    foreach ($snapshot['teams'] as $t) {
        $k = strtolower((string) $t['name']);

        // What stops a TRADE: the game-lock and §11's wager, and nothing else.
        $whyTrade = null;
        if (!empty($t['has_live_battle'])) {
            $whyTrade = 'battle';
        } elseif (isset($inGame[$k])) {
            $whyTrade = 'in_game';
        } elseif (isset($next[$k]) && $next[$k] - $now <= $lead) {
            $whyTrade = 'kickoff';
        }

        // A House transaction needs all of that PLUS a price that still stands, and the
        // PRECEDENCE is its own rather than $whyTrade's: Battle, then stale price, then
        // game-lock, so the owner is told the reason that lasts longest.
        //
        // STALE SINCE the later of this team's own last kickoff and the moment the week's
        // football finished — the second is what covers a team on a bye.
        $staleSince = max($last[$k] ?? 0, $boardStaleSince ?? 0) ?: null;

        $why = null;
        if (!empty($t['has_live_battle'])) {
            $why = 'battle';
        } else {
            if ($openedAt === null) {
                // No opening has ever settled: nothing played is fine, but a result nobody
                // has priced cannot be transacted on.
                $why = $staleSince !== null ? 'no_opening' : null;
            } elseif ($staleSince !== null && $staleSince >= $openedAt) {
                $why = 'unpriced';
            }
            if ($why === null) {
                $why = $whyTrade;              // the game-lock, reported last
            }
        }

        $out[(int) $t['id']] = [
            'available'  => $why === null,
            'why'        => $why === null ? null : PP_UNAVAILABLE_REASONS[$why],
            'tradable'   => $whyTrade === null,
            'why_trade'  => $whyTrade === null ? null : PP_UNAVAILABLE_REASONS[$whyTrade],
        ];
    }

    return ['teams' => $out];
}
