<?php

// Pure decider for settling (or refunding) an accepted battle — no DB. Both stakes
// were already reserved when the battle was accepted; here we decide the split.
// $battle is the accepted battle row (null = not found/not accepted).
//
// §11 sends the league's House Fee of every pot to the House. READ THE ROW, NEVER THE
// SETTING: each Battle snapshots the rate in force when it was created, so the live setting
// would re-price a wager two owners had already agreed to.
//
// Returns one of:
//   ['ok'=>true, 'mode'=>'refund', 'stake']
//   ['ok'=>true, 'mode'=>'settle', 'winner', 'pot', 'cut', 'payout', 'stake']
//   ['ok'=>false, 'code', 'error']

function decide_battle_settlement(?array $battle, bool $refund, int $winnerOwnerId): array
{
    if ($battle === null) {
        return ['ok' => false, 'code' => 404, 'error' => 'Battle not found or not accepted'];
    }
    $stake = (int)$battle['stake_cents'];

    if ($refund) {
        return ['ok' => true, 'mode' => 'refund', 'stake' => $stake];
    }

    if (!in_array($winnerOwnerId, [(int)$battle['owner_a_id'], (int)$battle['owner_b_id']], true)) {
        return ['ok' => false, 'code' => 400, 'error' => 'Winner must be one of the two owners'];
    }
    $pot = $stake * 2;
    $cut = (int) round($pot * (float)$battle['house_pct'] / 100);
    return ['ok' => true, 'mode' => 'settle', 'winner' => $winnerOwnerId,
            'pot' => $pot, 'cut' => $cut, 'payout' => $pot - $cut, 'stake' => $stake];
}
