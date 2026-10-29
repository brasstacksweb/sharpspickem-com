<?php

// Pure decider for whether a confirmed owner-to-owner trade may SETTLE — no DB.
// Owner-to-owner cash never touches the House.
//
// §9 caps a trade at ONE TEAM IN EACH DIRECTION plus cash. Both teams move and the cash
// moves in the same transaction, or nothing does: this returns the whole exchange as one
// set of effects, and the caller applies all of it or none of it.
//
// `ok=false` MEANS "CANNOT SETTLE YET", NOT "REFUSED". §9 holds anything this declines and
// tries again at the next opening; the CALLER decides how to say that. There is no
// queue-time twin for the same reason: refusing at propose time would be a rejection,
// decided against a snapshot that may be a week stale by then.
//
// $s: max_teams, stake,
// teams  => [team_id => ['name', 'owner_id', 'unavailable', 'basis', 'extra_games']]
// owners => [owner_id => ['name', 'funds', 'teams_held', 'extra_games']]
// Returns ['ok'=>true, 'moves'=>[…], 'cash_cents'=>int]  |  ['ok'=>false, 'code', 'error'].

/**
 * WHAT ONE TEAM IS RECORDED AT — the only arithmetic in a trade, and the one that is not
 * obvious. Pure, and split out so `TradeDecisionTest` can hit it directly.
 *
 * A TRADE RE-BASES; IT DOES NOT RE-PRICE. The team you receive takes on the basis of the
 * team you gave up, adjusted by the cash, and you realize a gain only to the extent the
 * cash exceeds that basis.
 *
 * That is very nearly forced. `check_ledger_consistency()`'s property 9 requires, for each
 * owner,
 *
 *     Σ(amount_cents on the legs they give up) − Σ(basis booked on what they receive)
 *       = the net cash they receive
 *
 * THE INTUITIVE CONVENTION CANNOT SATISFY IT: recording each team at Market Value would
 * demand `MV(given) − MV(received) = cash`, and §9 exists precisely so owners may agree any
 * price they like.
 *
 * What it changes is the split between an owner's REALIZED and UNREALIZED figures, never
 * their net, so no standing depends on it. An accounting convention, not a rule, which is
 * why it lives here and not on /rules.
 *
 * $givenBasis what the team they are giving up cost them, or null if they give none
 * $receives whether a team is coming back the other way
 * $cash net cash THIS owner receives, signed: negative means they pay
 *
 * Returns ['amount_cents' => ?int, 'new_basis_cents' => ?int] — the first for the leg they
 * give up (null if none), the second for what they book on the team they receive (null if
 * none). By construction `amount − new_basis = cash`, which is the identity above.
 */
function trade_allocation(?int $givenBasis, bool $receives, int $cash): array
{
    $gives = $givenBasis !== null;

    if ($gives && !$receives) {
        // They hand over a team for cash: exactly a sale. `ck_trade_cash_backed` guarantees
        // $cash >= 0 here — an owner cannot give up a team, pay cash, and receive nothing.
        return ['amount_cents' => $cash, 'new_basis_cents' => null];
    }
    if (!$gives && $receives) {
        // They buy: the team is booked at what they paid. $cash <= 0 here, for the
        // mirror-image reason.
        return ['amount_cents' => null, 'new_basis_cents' => -$cash];
    }
    if (!$gives && !$receives) {
        // Unreachable through `trades` — ck_trade_moves_a_team means at least one team moves.
        // Answered anyway rather than left to fall through as a silent zero.
        return ['amount_cents' => null, 'new_basis_cents' => null];
    }

    // A swap. The basis rolls across, less any cash they take out of it; take out more
    // cash than the team ever cost and the excess — and only the excess — is realized.
    $basis    = max(0, (int) $givenBasis - $cash);
    return ['amount_cents' => $basis + $cash, 'new_basis_cents' => $basis];
}

function decide_trade_settlement(?array $tx, array $s): array
{
    if ($tx === null) {
        return ['ok' => false, 'code' => 404, 'error' => 'Trade not found'];
    }
    if (empty($tx['counterparty_confirmed'])) {
        return ['ok' => false, 'code' => 400, 'error' => 'Both owners must confirm before a trade settles'];
    }

    $a = (int) $tx['owner_a_id'];
    $b = (int) $tx['owner_b_id'];
    $cash = (int) $tx['cash_cents'];            // signed, from A's side: >0 means B pays A
    // team_a travels A -> B, team_b travels B -> A.
    $sending = [];
    if ($tx['team_a_id'] !== null) {
        $sending[(int) $tx['team_a_id']] = [$a, $b];
    }
    if ($tx['team_b_id'] !== null) {
        $sending[(int) $tx['team_b_id']] = [$b, $a];
    }
    if (!$sending) {
        return ['ok' => false, 'code' => 400, 'error' => 'A trade has to move a team'];
    }

    $team  = fn (int $id): array => $s['teams'][$id] ?? ['name' => "team {$id}", 'owner_id' => 0,
        'unavailable' => true, 'basis' => 0, 'extra_games' => 0];
    $owner = fn (int $id): array => $s['owners'][$id] ?? ['name' => "owner {$id}", 'funds' => 0,
        'teams_held' => 0, 'extra_games' => 0];

    // ---- Is the trade still the trade both owners agreed to? ------------------------
    // Ownership first: a team that has changed hands makes the exchange a different one, and
    // saying so beats reporting whichever of the checks below happens to fire.
    foreach ($sending as $teamId => [$from, $to]) {
        $t = $team($teamId);
        if ((int) $t['owner_id'] !== $from) {
            return ['ok' => false, 'code' => 400, 'error' =>
                           $owner($from)['name'] . ' no longer owns ' . $t['name']];
        }
    }

    // §6: EVERY team in the exchange has to be tradable, and one that is not holds the WHOLE
    // trade — half a swap is a different trade neither owner agreed to.
    //
    // TRADABLE is a wider test than available: a trade is not governed by Market Value, so
    // only the game-lock and §11's live wager stop one. It holds through the playoff too —
    // there is no postseason freeze (Q18).
    foreach ($sending as $teamId => $_) {
        $t = $team($teamId);
        if (!empty($t['unavailable'])) {
            return ['ok' => false, 'code' => 400, 'error' =>
                           $t['name'] . ' cannot be traded yet (§6)'];
        }
    }

    // ---- Both sides, every time -----------------------------------------------------
    // A swap has no buyer and no seller, so everything below is evaluated for A and for B.
    $max = (int) $s['max_teams'];
    $moves = [];
    foreach ([[$a, $cash], [$b, -$cash]] as [$who, $theirCash]) {
        $o = $owner($who);
        $givenId = null;
        $gotId   = null;
        foreach ($sending as $teamId => [$from, $to]) {
            if ($from === $who) {
                $givenId = $teamId;
            }
            if ($to === $who) {
                $gotId = $teamId;
            }
        }

        $teamsAfter = (int) $o['teams_held'] + ($gotId !== null ? 1 : 0) - ($givenId !== null ? 1 : 0);
        if ($teamsAfter > $max) {
            return ['ok' => false, 'code' => 400, 'error' =>
                           $o['name'] . ' would be over the ' . $max . '-team maximum'];
        }

        $cashOut = max(0, -$theirCash);
        if ($cashOut > (int) $o['funds']) {
            return ['ok' => false, 'code' => 400, 'error' =>
                           $o['name'] . ' does not have enough Available Funds for the cash side of this trade'];
        }

        // §11's MARGIN CALL (Q20): an owner already short may not take on more — but a trade
        // that is EVEN or SHRINKS their ROSTER is one of the named ways OUT, so only a
        // roster-growing trade is refused.
        //
        // It counts TEAMS, not value, and the sentences below must keep saying so: swapping
        // one team for a better one is even, and refusing it would close an exit the ruling
        // opened.
        $grows = ($gotId !== null ? 1 : 0) - ($givenId !== null ? 1 : 0) > 0;
        if ($grows && !empty($o['margin_call'])) {
            return ['ok' => false, 'code' => 400, 'error' =>
                           $o['name'] . ' is under Margin Call (§11) and cannot take on another team until '
                           . 'their Battle reserve is covered. A trade that leaves them holding no more teams '
                           . 'than they do now is fine, whatever it is worth.'];
        }
        // ...NOR MAY THEY PAY CASH, the other way to get worse without growing. The reserve
        // check below is skipped for an owner already under Margin Call, so without this an
        // even swap carrying cash takes them FURTHER under the line and §11's published "the
        // only way to drop below the reserve is by losing Battles" is false.
        //
        // Every exit Q20 named stays open: an even swap with no cash, a team traded away FOR
        // cash, a drop, a sale.
        if ($cashOut > 0 && !empty($o['margin_call'])) {
            return ['ok' => false, 'code' => 400, 'error' =>
                           $o['name'] . ' is under Margin Call (§11) and cannot pay cash until their Battle '
                           . 'reserve is covered. The same trade without cash is fine.'];
        }

        // §11. Q21: the reserve covers every GAME a held team plays this week, so a team
        // arriving brings its extra games with it and one leaving takes its own away.
        $extra = (int) $o['extra_games']
            + ($gotId !== null ? (int) $team($gotId)['extra_games'] : 0)
            - ($givenId !== null ? (int) $team($givenId)['extra_games'] : 0);
        $r = decide_reserve_headroom([
            'funds'        => (int) $o['funds'],
            'stake'        => (int) $s['stake'],
            'max_teams'    => $max,
            'teams_held'   => (int) $o['teams_held'],
            'teams_gained' => ($gotId !== null ? 1 : 0) - ($givenId !== null ? 1 : 0),
            'extra_games'  => max(0, $extra),
            'escrow'       => (int) ($o['escrow'] ?? 0),
            'cash_out'     => $cashOut,
            'battles_possible' => (bool) ($s['battles_possible'] ?? true),
        ]);
        // Only bites when the trade would CREATE a shortfall: an owner already under Margin
        // Call is handled above, and refusing them here too would close the ruling's exits.
        if (!$r['ok'] && empty($o['margin_call'])) {
            return ['ok' => false, 'code' => 400, 'error' =>
                           $o['name'] . ' would be left with ' . money($r['funds'] - $r['cash_out'])
                           . ', below the ' . money($r['reserve']) . ' that has to stay back to cover Battle stakes for '
                           . reserve_teams_label($r['teams_after'])];
        }

        $alloc = trade_allocation(
            $givenId === null ? null : (int) ($team($givenId)['basis'] ?? 0),
            $gotId !== null,
            $theirCash
        );
        if ($givenId !== null) {
            $moves[$givenId]['team_id']      = $givenId;
            $moves[$givenId]['from']         = $who;
            $moves[$givenId]['to']           = $sending[$givenId][1];
            $moves[$givenId]['basis_cents']  = (int) ($team($givenId)['basis'] ?? 0);
            $moves[$givenId]['amount_cents'] = (int) $alloc['amount_cents'];
        }
        if ($gotId !== null) {
            // Booked by the RECEIVING owner, which is why it is written on the other
            // owner's pass through this loop than the amount on the same team's leg.
            $moves[$gotId]['new_basis_cents'] = (int) $alloc['new_basis_cents'];
        }
    }

    return ['ok' => true, 'moves' => array_values($moves), 'cash_cents' => $cash];
}
