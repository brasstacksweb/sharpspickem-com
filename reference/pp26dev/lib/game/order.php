<?php

/**
 * §6's Close of the season, in one sentence, because THREE routes refuse with it and an
 * owner must not be told three different things about one rule: this decider (bids, adds,
 * drops, sales) and the two trade actions, which do not come through here.
 */
const PP_SEASON_CLOSED = 'The season is over — the market reopens with next season\'s draft.';

/**
 * Pure decider for whether an owner may QUEUE a market order — no DB, no IO.
 *
 * This decides what may go into the queue; `process_opening()` decides what actually
 * happens. Anything that can change between the two moments (who owns what, who has room)
 * is re-checked at resolution and only REPORTED here.
 *
 * WHAT IS CHECKED HERE
 *   - the window is open, and the season is running;
 *   - the order makes sense for the team (no bidding on a team you own, no adding a
 *     ranked one, no selling an unranked one or selling at all once §8 has closed);
 *   - one order per team — see below;
 *   - and for a bid, that the owner can afford it INCLUDING the Battle reserve.
 *
 * WHAT IS NOT CHECKED HERE
 *   The portfolio cap (Q25). An owner may queue more than they can hold, because a drop or
 *   sale queued in the same window frees a slot and which bids win is not known until they
 *   resolve. `resolve_bids()` and the adds step enforce it against the roster as it ends
 *   up, and say so in the order's outcome.
 *
 * ONE ORDER PER TEAM, PER OWNER, PER OPENING, enforced here and by `uq_order`. It is what
 * keeps the resolution order free of special cases: an owner cannot queue a drop AND a sale
 * for one team, so no step has to arbitrate a conflict with themselves.
 *
 * THE BATTLE RESERVE (§11, Spencer). Battles are mandatory, so a bid must leave behind:
 *
 * other open bids + this bid + (teams they could end up holding × stake) ≤ funds
 *
 * "Could end up holding" is capped at `max_teams` — reserving for ten queued adds when only
 * five can land locks up money for teams that cannot exist.
 *
 * Returns ['ok'=>true] | ['ok'=>false, 'code', 'error'].
 */
function decide_market_order(array $order, array $snapshot): array
{
    $kind = (string) $order['kind'];
    $team = $snapshot['team'] ?? null;
    $name = $team['name'] ?? 'That team';

    // THE SEASON IS OVER AND THE MARKET WITH IT — §6's Close of the season, which §4 and
    // §12 run "right through the Championship Game": through, not past. A purchase after it
    // pays Market Value INTO a House that §10 requires to end the season at $0.00, and
    // season_settlement_status() then refuses to close the year. One $3.00 buy is enough.
    if (!empty($snapshot['season_over'])) {
        return ['ok' => false, 'code' => 400, 'error' => PP_SEASON_CLOSED];
    }
    if (($snapshot['phase'] ?? '') !== 'regular') {
        return ['ok' => false, 'code' => 400, 'error' => match ($snapshot['phase'] ?? '') {
            'draft'    => 'The market opens once the draft is complete.',
            default    => 'The market opens once the preseason draft is complete.',
        }];
    }
    if ($team === null) {
        return ['ok' => false, 'code' => 404, 'error' => 'Team not found'];
    }
    if (!empty($snapshot['has_order_for_team'])) {
        return ['ok' => false, 'code' => 409, 'error' =>
                   "You already have an order for {$name} this window. Cancel it first if you want to do something else with them."];
    }
    // §11 (Q20): an owner under MARGIN CALL may not increase their exposure, so this gates
    // the ACQUIRING kinds only — dropping and selling are two of the four ways out.
    //
    // Before the per-kind switch, because the reason is about the OWNER rather than the
    // team. The forward-looking reserve check below still applies to owners who are NOT in
    // Margin Call, which keeps §11's "the only way to drop below the reserve is by losing
    // Battles" literally true.
    if (!empty($snapshot['margin_call']) && in_array($kind, ['bid', 'add'], true)) {
        return ['ok' => false, 'code' => 400, 'error' =>
                   'You are under Margin Call (§11) — your Available Funds are below the Battle reserve '
                   . 'for the teams you already hold, so you cannot take on another until it is covered. '
                   . 'Add funds, sell or trade a team, or drop one.'];
    }

    // §9: a team already promised in a pending trade is spoken for. A trade that cannot
    // settle is HELD rather than cancelled, so a sale settling first (step 2 of an opening,
    // against the trade's step 3) leaves that trade unsettleable for ever.
    if (!empty($snapshot['in_pending_trade'])) {
        return ['ok' => false, 'code' => 409, 'error' =>
                   "{$name} is part of a trade you have not settled yet. Cancel the trade first if you "
                   . 'want to do something else with them.'];
    }

    // §6: an available team is acted on NOW, an unavailable one is queued to the next
    // opening. Not a rejection — the owner is told which rule is holding it and the order
    // stands. Everything refused above is refused because no later opening can help it.
    $available = empty($snapshot['locked']);
    $mode      = $available ? 'execute' : 'queue';
    $queueWhy  = $available ? null : (string)($snapshot['unavailable_why'] ?? 'it is not available right now');

    // A CONDITIONAL DROP ALWAYS QUEUES, whatever §6 says about the team: it waits on the
    // OUTCOME of a pending acquisition, which is not known until the opening.
    //
    // DO NOT REFUSE IT WHEN THE TEAM IS AVAILABLE. The only alternative left to the owner is
    // dropping outright, which gives the team up whether or not the bid wins — the harm §8
    // invented the conditional drop to prevent. §6 is still enforced at the opening.
    if (!empty($order['conditional'])) {
        $mode     = 'queue';
        // §8: it fires only if that acquisition lands AND the spot is needed, and expires
        // with the opening otherwise — so this must not promise it settles.
        $queueWhy = 'it is held against the order you filed it with, and is given up only if '
                  . 'that lands and you need the room — otherwise it expires with the opening';
    }

    // THE TEAM CAP binds only when the order executes NOW. A queued order is deliberately
    // not capped: a drop queued alongside it may free the slot.
    $ok = static fn (): array => ['ok' => true, 'mode' => $mode, 'why' => $queueWhy];

    // MAKING ROOM IN THE SAME BREATH (§8): an owner at the cap may name a team to give up,
    // and the two happen as one. REJECTED rather than ignored when it cannot be honoured —
    // silently buying nothing, or dropping without buying, are both worse than a sentence.
    //
    // Immediate path only. Queued, it would give the team up whether or not the sealed bid
    // won, which is what §8's conditional drop exists to avoid.
    $drop = $snapshot['drop_team'] ?? null;
    if ($drop !== null) {
        if ($mode !== 'execute') {
            return ['ok' => false, 'code' => 400, 'error' =>
                "{$name} is off the board, so this order queues to the next opening — file a "
                . 'conditional drop with it instead, so you only give a team up if the bid wins.'];
        }
        if ($kind !== 'bid' && $kind !== 'add') {
            return ['ok' => false, 'code' => 400, 'error' => 'Only an acquisition can make room for itself.'];
        }
        if ((int)($drop['owner_id'] ?? 0) !== (int) $snapshot['owner_id']) {
            return ['ok' => false, 'code' => 400, 'error' => 'You do not hold the team you offered to give up.'];
        }
        if ((int)$drop['id'] === (int)($team['id'] ?? 0)) {
            return ['ok' => false, 'code' => 400, 'error' => "You cannot give up {$name} to acquire it."];
        }
        if (!empty($snapshot['drop_in_trade'])) {
            return ['ok' => false, 'code' => 409, 'error' =>
                "{$drop['name']} is committed to a pending trade — cancel the trade first (§9)."];
        }
        if (!empty($snapshot['drop_has_order'])) {
            return ['ok' => false, 'code' => 409, 'error' =>
                "{$drop['name']} already has an order this window — a team can only be promised once."];
        }
        if (empty($snapshot['drop_available'])) {
            return ['ok' => false, 'code' => 409, 'error' =>
                "{$drop['name']} is off the board, so it cannot be released now (§6)."];
        }
        // §8: the spot exists at the moment the acquisition is finalized, so the cap and
        // the reserve are both measured against the roster this order LEAVES BEHIND.
        $snapshot['teams_held']  = max(0, (int) $snapshot['teams_held'] - 1);
        $snapshot['funds']       = (int) $snapshot['funds'] + (int) ($snapshot['drop_proceeds'] ?? 0);
        $snapshot['extra_games'] = max(0, (int) ($snapshot['extra_games'] ?? 0)
                                          - (int) ($snapshot['drop_extra_games'] ?? 0));
    }

    $atCap = (int) $snapshot['teams_held'] >= (int) $snapshot['max_teams'];

    $mine = ($team['owner_id'] ?? null) !== null && (int)$team['owner_id'] === (int)$snapshot['owner_id'];
    $house = ($team['owner_id'] ?? null) === null;

    switch ($kind) {
        case 'bid':
            if (!$house) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   $mine ? "You already own {$name}." : "{$name} is owned by another owner — bidding is for House teams."];
            }
            if (empty($snapshot['ranked'])) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   "{$name} is unranked — it costs nothing, so add it free instead of bidding."];
            }
            if ($mode === 'execute' && $atCap) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   "You already hold {$snapshot['max_teams']} teams. Drop or sell one first — "
                                   . "{$name} is available now, so there is no queue to make room in."];
            }
            $amount = (int) $order['amount'];
            if ($amount <= 0) {
                return ['ok' => false, 'code' => 400, 'error' => 'A bid must be more than $0.'];
            }
            if ($amount < (int)$snapshot['mv']) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   'A bid must be at least the Market Value (' . money((int)$snapshot['mv']) . ').'];
            }
            $a = decide_bid_affordability($amount, $snapshot);
            return $a['ok'] ? $ok() : $a;

        case 'add':
            if (!$house) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   $mine ? "You already own {$name}." : "{$name} is already owned."];
            }
            if (!empty($snapshot['ranked'])) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   "{$name} is ranked — ranked teams are acquired by bidding. Adding free is for teams outside the Top 25."];
            }
            if ($mode === 'execute' && $atCap) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   "You already hold {$snapshot['max_teams']} teams. Drop or sell one first — "
                                   . "{$name} is available now, so there is no queue to make room in."];
            }
            // The team is free; HOLDING it is not — §11 needs a stake behind every team, so
            // a free add still raises what has to stay in the account. The message says so.
            $r = decide_reserve_headroom([
                'funds'        => (int) $snapshot['funds'],
                'stake'        => (int) $snapshot['stake'],
                'max_teams'    => (int) $snapshot['max_teams'],
                'teams_held'   => (int) $snapshot['teams_held'],
                'teams_gained' => (int) $snapshot['pending_gains'] + 1,
                'extra_games'  => (int) ($snapshot['extra_games'] ?? 0)
                                  + (int) ($snapshot['team_extra_games'] ?? 0),
                'escrow'       => (int) ($snapshot['escrow'] ?? 0),
                'cash_out'     => (int) $snapshot['committed_cents'],
                'battles_possible' => (bool) ($snapshot['battles_possible'] ?? true),
            ]);
            if (!$r['ok']) {
                $msg = "{$name} costs nothing, but every team you hold needs a Battle stake behind it. You have "
                     . money($r['funds']);
                if ($r['cash_out'] > 0) {
                    $msg .= ', with ' . money($r['cash_out']) . ' committed to bids';
                }
                $msg .= ', and ' . money($r['reserve']) . ' would have to stay back for '
                      . reserve_teams_label($r['teams_after']) . '.';
                return ['ok' => false, 'code' => 400, 'error' => $msg];
            }
            return $ok();

        case 'drop':
            if (!$mine) {
                return ['ok' => false, 'code' => 400, 'error' => 'You do not own that team.'];
            }
            return $ok();

        case 'sale':
            if (!$mine) {
                return ['ok' => false, 'code' => 400, 'error' => 'You do not own that team.'];
            }
            // §8 (Spencer): the House's willingness to buy narrows in three stages. Only
            // this direction closes — trades and purchases FROM the House continue. Also
            // re-checked at settlement, since a boundary can pass in between.
            $stage = (string) ($snapshot['buyback_stage'] ?? 'open');
            if ($stage === 'closed') {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   'The House stopped buying teams for the season on the date the Commissioner '
                                   . "set before the draft (§8). You can still trade {$name} to another owner, "
                                   . 'or drop them for free.'];
            }
            if (empty($snapshot['ranked'])) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   "{$name} is unranked — the House only buys teams in the AP or CFP Top 25. Drop it instead (free)."];
            }
            // house_will_buy() rather than a second copy of the rank test: §8's staging is
            // one predicate.
            $rank = $snapshot['rank_pos'] ?? null;
            if (!house_will_buy($stage, $rank === null ? null : (int) $rank)) {
                return ['ok' => false, 'code' => 400, 'error' =>
                                   "{$name} is ranked #" . (int) $rank . ' — the House now only buys teams in the '
                                   . 'top ' . PP_CFP_FIELD_SIZE . ' (§8). You can still trade them to another '
                                   . 'owner, or drop them for free.'];
            }
            return $ok();
    }
    return ['ok' => false, 'code' => 400, 'error' => 'Unknown order type'];
}

/**
 * Can this owner cover a new bid, once their other open bids and the Battle reserve are
 * taken out? The error has to explain which of the three things ran out.
 */
function decide_bid_affordability(int $amount, array $snapshot): array
{
    $funds = (int) $snapshot['funds'];
    $committed = (int) $snapshot['committed_cents'];

    $r = decide_reserve_headroom([
        'funds'        => $funds,
        'stake'        => (int) $snapshot['stake'],
        'max_teams'    => (int) $snapshot['max_teams'],
        'teams_held'   => (int) $snapshot['teams_held'],
        'teams_gained' => (int) $snapshot['pending_gains'] + 1,   // this bid, if it wins
        'extra_games'  => (int) ($snapshot['extra_games'] ?? 0)
                          + (int) ($snapshot['team_extra_games'] ?? 0),
        'escrow'       => (int) ($snapshot['escrow'] ?? 0),
        'cash_out'     => $committed + $amount,
        'battles_possible' => (bool) ($snapshot['battles_possible'] ?? true),
    ]);

    if (!$r['ok']) {
        $msg = 'That bid would leave you short. You have ' . money($funds);
        if ($committed > 0) {
            $msg .= ', with ' . money($committed) . ' already committed to other bids';
        }
        $msg .= ', and ' . money($r['reserve']) . ' has to stay back to cover Battle stakes for '
              . reserve_teams_label($r['teams_after'])
              // Headroom is negative by exactly the overspend, so adding this bid back
              // gives what they could have bid instead.
              . ' — so the most you can bid here is ' . money(max(0, $r['headroom'] + $amount)) . '.';
        return ['ok' => false, 'code' => 400, 'error' => $msg];
    }
    return ['ok' => true];
}

/**
 * How long until the next market opening — the countdown behind the dashboard chip.
 *
 * IT COUNTS TO AN OPENING, NOT TO "THE MARKET OPENING": the market runs continuously while
 * there is a season (§6/Q18), and what arrives on a schedule is the settlement moment.
 *
 * $settlesAt IS LEAGUE-LOCAL WALL TIME — `market_openings.settles_at` — so the caller passes
 * that league's zone and nothing here reads a clock of its own. Parsing it under PHP's UTC
 * default is a countdown wrong by the league's whole UTC offset.
 *
 * THE ROUND TRIP IS THE VALIDATION: createFromFormat() silently rolls a date the calendar
 * does not have, so comparing the reparsed string back is the only thing that refuses one.
 *
 * GOES QUIET RATHER THAN COUNTING PAST ZERO — an arrived opening settles on the next page
 * load (catch_up_league()).
 *
 * Returns null when there is nothing to count to, else
 * ['at_ts' => int, 'seconds' => int >= 0, 'due' => bool, 'phrase' => string].
 */
function decide_opening_countdown(?string $settlesAt, int $nowTs, DateTimeZone $tz): ?array
{
    if ($settlesAt === null || $settlesAt === '') {
        return null;
    }
    // '!' so unspecified microseconds come from the epoch and two calls in the same second
    // cannot disagree.
    $at = DateTimeImmutable::createFromFormat('!Y-m-d H:i:s', $settlesAt, $tz);
    if ($at === false || $at->format('Y-m-d H:i:s') !== $settlesAt) {
        return null;
    }

    $left = $at->getTimestamp() - $nowTs;
    $secs = max(0, $left);

    // THE PHRASE IS DEFINED HERE AND MIRRORED IN assets/util.js, which re-formats it every
    // second. Two renderings because the first has to survive JS being off; keep the rule
    // this coarse so a discrepancy is visible.
    if ($secs === 0) {
        $phrase = 'settling now';
    } elseif ($secs < 60) {
        $phrase = 'in under a minute';
    } elseif ($secs < 3600) {
        $phrase = 'in ' . intdiv($secs, 60) . 'm';
    } elseif ($secs < 86400) {
        $phrase = 'in ' . intdiv($secs, 3600) . 'h ' . intdiv($secs % 3600, 60) . 'm';
    } else {
        $phrase = 'in ' . intdiv($secs, 86400) . 'd ' . intdiv($secs % 86400, 3600) . 'h';
    }

    return [
        'at_ts'   => $at->getTimestamp(),
        'seconds' => $secs,
        'due'     => $left <= 0,
        'phrase'  => $phrase,
    ];
}

/**
 * When the market next REPRICES the board — the moment a played team comes back on it, and
 * the one an order waiting on a price settles at.
 *
 * NOT next_market_open(), which returns the next occurrence of the league's configured HOUR
 * and knows nothing about polls, so it names a morning that may reprice nothing.
 *
 * TWO TIERS, and `exact` says which. Once a poll has landed its opening is a real row with a
 * real settles_at. Before that the answer is derived from the poll's cadence — the AP Sunday
 * afternoon, the Committee from PP_CFP_FIRST_WEEK Tuesday evening — landing at the league's
 * hour the following morning.
 *
 * THE DERIVED HALF IS AN ESTIMATE and is held to the same terms as PP_CFP_FIRST_WEEK: it
 * decides no money and gates nothing. CFBD publishes no poll timestamps at all, only week
 * numbers, which is why the cadence is stated rather than read.
 *
 * $snapshot: [
 *   'scheduled_at' => ?int,   -- epoch of an OPEN opening that carries a poll, or null
 *   'week'         => int,    -- football week, for the AP -> CFP switch
 *   'last_game_at' => ?int,   -- epoch of this week's LAST kickoff, or null
 *   'open_time'    => string, -- the league's market_open_time, 'HH:MM'
 *   'now'          => int,
 *   'tz'           => DateTimeZone,
 * ]
 *
 * Returns ['at' => int, 'exact' => bool].
 */
function decide_next_pricing_open(array $snapshot): array
{
    if ($snapshot['scheduled_at'] !== null) {
        return ['at' => (int) $snapshot['scheduled_at'], 'exact' => true];
    }

    $tz  = $snapshot['tz'];
    $now = (new DateTime('@' . (int) $snapshot['now']))->setTimezone($tz);
    [$h, $m] = array_pad(explode(':', (string) $snapshot['open_time']), 2, '00');

    // THE AP POLL FOLLOWS THE WEEK'S LAST GAME, on no fixed weekday. Assuming Sunday is wrong
    // exactly where it matters: 2026's week 1 ran to a Labour Day MONDAY, so the poll was due
    // the Tuesday and the opening the Wednesday, while a Sunday rule named the Monday after —
    // five days late, on owners' dashboards.
    //
    // The COMMITTEE does publish on a fixed evening from PP_CFP_FIRST_WEEK, so that half
    // keeps its weekday and takes the first Tuesday on or after the last game.
    //
    // Read on the LEAGUE's clock: week 2's last kickoff is 03:59 UTC, which is the Saturday
    // night before, and a poll day off by one carries the opening with it.
    $day = (new DateTime('@' . ($snapshot['last_game_at'] ?? (int) $snapshot['now'])))->setTimezone($tz);
    if ((int) $snapshot['week'] >= PP_CFP_FIRST_WEEK) {
        while ((int) $day->format('N') !== 2) {
            $day->modify('+1 day');
        }
    } else {
        $day->modify('+1 day');
    }

    // The poll lands that afternoon; the opening is the NEXT morning. Clamped forward so a
    // poll that has not arrived on time never names a moment behind us.
    $open = (clone $day)->modify('+1 day')->setTime((int) $h, (int) $m, 0);
    while ($open <= $now) {
        $open->modify('+1 day');
    }

    return ['at' => $open->getTimestamp(), 'exact' => false];
}
