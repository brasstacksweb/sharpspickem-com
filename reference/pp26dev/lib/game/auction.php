<?php

// Pure blind-auction resolver — no DB, no IO. Decides each team's outcome from a state
// snapshot so the logic is exhaustively unit-testable; process_opening_bids() loads the
// snapshot, calls this, and applies the decisions inside the opening's transaction.
//
// §7's promise, and Q23: "only the highest-priority bids that fit within the owner's
// available portfolio space will be processed." §6 and §8 say anything over the limit is
// void and the next-highest bidder inherits — the other half of the same mechanism, not a
// rival answer, and both are true below.
//
// THE SHAPE IS DEFERRED ACCEPTANCE, because a single pass cannot answer it. An owner's
// capacity is contested by several teams at once, and releasing one of their wins hands
// that team to somebody else — who may then be over capacity themselves. So:
//
//   1. every unawarded team nominates its highest bid that has not been rejected;
//   2. each owner takes their nominations IN PRIORITY ORDER and accepts what fits —
// capacity, conditional drops, funds and §11's reserve, simulated exactly as the
// sequential apply will make them — and rejects the rest;
//   3. a rejected bid lets that team fall to its next-highest bidder, so repeat.
//
// It terminates because a round that changes anything rejects at least one bid, and there
// are finitely many. Rejections are permanent by design: handing a team back because its
// first owner later had room would make the outcome depend on the order the rounds ran in.
//
// Inputs:
//   $teams ordered list (the caller's order decides only how the report reads):
//     [ ['team_id'=>int, 'team_name'=>string, 'is_house'=>bool, 'extra_games'=>int,
//        'bids'=>[ ['bid_id'=>int, 'owner_id'=>int, 'amount'=>int, 'priority'=>int], ... ]], ... ]
// each 'bids' list pre-sorted: highest amount first, earliest first on ties.
//     'priority' is the OWNER's ranking of their own bids, ascending — lower is kept first.
//   $owners [owner_id => ['funds'=>int, 'teams'=>int, 'extra_games'=>int]]
//   $maxTeams int
//   $drops  [owner_id => [ ['drop_id'=>int,'team_id'=>int], ... ]]   FIFO, still-owned
//
// Output: a flat, ordered decision list the wrapper applies and reports verbatim:
//   ['type'=>'skipped','team_id','team_name','reason']
//   ['type'=>'void','team_id','team_name','owner_id','amount','bid_id','reason']
//   ['type'=>'won','team_id','team_name','owner_id','amount','bid_id','drop'=>['drop_id','team_id']|null]

function resolve_bids(array $teams, array $owners, int $maxTeams, array $drops, int $stake,
    bool $battlesPossible = true): array
{
    $out = [];
    $lots = [];                      // team_id => the team row, house-owned only
    foreach ($teams as $t) {
        $tid = (int) $t['team_id'];
        if (empty($t['is_house'])) {
            $out[] = ['type' => 'skipped', 'team_id' => $tid,
                      'team_name' => (string) ($t['team_name'] ?? ''), 'reason' => 'no longer a House team'];
            continue;
        }
        $lots[$tid] = $t;
    }

    $rejected = [];                  // "teamId:bidId" => reason
    $accepted = [];                  // team_id => ['bid'=>…, 'drop'=>…], from the final round

    while (true) {
        // 1. Each lot nominates its best surviving bid.
        $nominations = [];           // owner_id => [ ['tid'=>…, 'bid'=>…], … ]
        foreach ($lots as $tid => $t) {
            foreach ($t['bids'] as $b) {
                if (!isset($rejected[$tid . ':' . (int) $b['bid_id']])) {
                    $nominations[(int) $b['owner_id']][] = ['tid' => $tid, 'bid' => $b];
                    break;
                }
            }
        }

        // 2. Each owner accepts what fits, in THEIR priority order.
        $accepted = [];
        $changed = false;
        foreach ($nominations as $oid => $noms) {
            usort($noms, static fn ($x, $y) =>
                           ((int) ($x['bid']['priority'] ?? 0) <=> (int) ($y['bid']['priority'] ?? 0))
                           ?: ((int) $x['bid']['bid_id'] <=> (int) $y['bid']['bid_id']));

            $o = $owners[$oid] ?? ['funds' => 0, 'teams' => 0];
            $funds = (int) $o['funds'];
            $held  = (int) $o['teams'];
            $extra = (int) ($o['extra_games'] ?? 0);
            $dropsLeft = count($drops[$oid] ?? []);
            $dropIdx = 0;

            foreach ($noms as $n) {
                $tid = $n['tid'];
                $bid = $n['bid'];
                $amt = (int) $bid['amount'];
                $key = $tid . ':' . (int) $bid['bid_id'];
                $lotExtra = (int) ($lots[$tid]['extra_games'] ?? 0);

                $reason = null;
                $atCap = $held >= $maxTeams;
                if ($funds < $amt) {
                    $reason = 'insufficient Available Funds';
                } elseif ($atCap && $dropsLeft <= 0) {
                    // The cap is decided BEFORE the reserve, because whether a drop frees a
                    // slot changes how many teams the reserve has to cover.
                    $reason = 'over the ' . $maxTeams . '-team max, no drop order';
                } else {
                    // §11: winning has to leave a stake behind for every game the teams they
                    // would then hold are playing. Queue time checked this too, but a trade
                    // settling since can have drained them, so this is the one that binds.
                    $teamsAfter = $held + 1 - ($atCap ? 1 : 0);
                    $r = decide_reserve_headroom([
                        'funds' => $funds, 'stake' => $stake, 'max_teams' => $maxTeams,
                        'teams_held' => $teamsAfter, 'teams_gained' => 0, 'cash_out' => $amt,
                        'extra_games' => $extra + $lotExtra,
                        'escrow' => (int) ($o['escrow'] ?? 0),
                        'battles_possible' => $battlesPossible,
                    ]);
                    if (!$r['ok']) {
                        $reason = 'not enough left over to cover the Battle stakes for '
                                . reserve_teams_label($r['teams_after']);
                    }
                }

                if ($reason !== null) {
                    if (!isset($rejected[$key])) {
                        $rejected[$key] = $reason;
                        $changed = true;
                    }
                    continue;
                }

                // Consume the drop only now the bid has actually WON. Spending one on a bid
                // about to be rejected would deny a later lot a slot it should have had.
                $drop = null;
                if ($atCap) {
                    $drop = $drops[$oid][$dropIdx] ?? null;
                    $dropIdx++;
                    $dropsLeft--;
                    $held -= 1;
                }
                $funds -= $amt;
                $held  += 1;
                $extra += $lotExtra;
                $accepted[$tid] = ['bid' => $bid, 'drop' => $drop];
            }
        }

        if (!$changed) {
            break;
        }
    }

    // 3. Emit in the caller's team order, so the report reads as the league sees it.
    foreach ($lots as $tid => $t) {
        $tname = (string) ($t['team_name'] ?? '');
        foreach ($t['bids'] as $b) {
            $key = $tid . ':' . (int) $b['bid_id'];
            $row = ['team_id' => $tid, 'team_name' => $tname, 'owner_id' => (int) $b['owner_id'],
                    'amount' => (int) $b['amount'], 'bid_id' => (int) $b['bid_id']];
            if (isset($accepted[$tid]) && (int) $accepted[$tid]['bid']['bid_id'] === (int) $b['bid_id']) {
                $out[] = ['type' => 'won'] + $row + ['drop' => $accepted[$tid]['drop']];
                break;                       // team awarded; lower bids are simply outbid
            }
            if (isset($rejected[$key])) {
                $out[] = ['type' => 'void'] + $row + ['reason' => $rejected[$key]];
                continue;
            }
            break;                           // outbid; the wrapper's sweep says so
        }
    }
    return $out;
}
