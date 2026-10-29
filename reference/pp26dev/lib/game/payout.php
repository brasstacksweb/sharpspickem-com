<?php

/**
 * Pure decider for what a playoff win is worth — no DB, no IO.
 *
 * §12 pays each playoff win a fixed percentage of the Prize Pool, and §10 promises the House
 * ends every season at $0.00. Those cannot both hold when a winning team has no owner, which
 * really happens: two of 2024's four first-round byes went to teams nobody had, and 6% of the
 * pool stayed in the House.
 *
 * Q14: an unowned team's share is **not** lost and does not stay in the House. It rolls
 * forward into the rounds still to be paid, pro-rata.
 *
 * One formula does all of it:
 *
 * amount = remaining pool × (this round's pct ÷ pct of every slot not yet recorded)
 *
 * A forfeited slot is still *recorded* — it just pays nothing — so it leaves the
 * denominator without taking anything out of the pool, and everything still to be paid
 * grows in proportion. Three properties fall out rather than being arranged:
 *
 *   - With nothing forfeited it reproduces the fixed percentages exactly.
 *   - The last slot computes `remaining × 40/40` — the whole remainder — so rounding
 * dust cannot survive to the end. §10's $0.00 is structural.
 *   - It needs no knowledge of the bracket. Each payout is decided from what is left
 * and what is still owed, both of which are already recorded.
 *
 * The one case it cannot close is the House owning the CHAMPION, where there is no later
 * round to roll into. Then `remainder_after` is what is left over, and the caller refunds it
 * to owners pro-rata by contribution (§10).
 *
 * $remainingPool  — Prize Pool minus everything already paid out.
 * $thisPct        — the nominal percentage for the round being recorded.
 * $unrecordedPct  — total nominal pct of every slot not yet recorded, INCLUDING this one.
 * $forfeited      — true when the winning team has no owner.
 *
 * Returns ['amount' => int cents, 'remainder_after' => int cents, 'is_last' => bool].
 */
function decide_playoff_share(
    int $remainingPool,
    float $thisPct,
    float $unrecordedPct,
    bool $forfeited
): array {
    // An unrecorded total of zero means the caller double-counted. Pay nothing rather than
    // divide by zero.
    if ($unrecordedPct <= 0.0) {
        return ['amount' => 0, 'remainder_after' => max(0, $remainingPool), 'is_last' => true];
    }

    $isLast = abs($unrecordedPct - $thisPct) < 0.0001;

    if ($forfeited) {
        return ['amount' => 0, 'remainder_after' => max(0, $remainingPool), 'is_last' => $isLast];
    }

    // The last payable slot takes the remainder outright: computed as a percentage it would
    // leave rounding dust in a House that has to end at $0.00.
    $amount = $isLast
        ? $remainingPool
        : (int) round($remainingPool * $thisPct / $unrecordedPct);

    $amount = max(0, min($amount, $remainingPool));

    return [
           'amount'          => $amount,
           'remainder_after' => $remainingPool - $amount,
           'is_last'         => $isLast,
       ];
}

/**
 * What each round's win would pay from a pool of $baseCents, with nothing forfeited — the
 * figures the dashboard prints beside §12's percentages. The same arithmetic as
 * decide_playoff_share() with the whole pool still owed, so an estimate and a payout cannot
 * disagree about rounding.
 *
 * $rounds — PP_PLAYOFF_ROUNDS' shape: round => ['pct' => float, …].
 *
 * Returns [round => cents] in the order given.
 */
function decide_payout_estimates(int $baseCents, array $rounds): array
{
    $out = [];
    foreach ($rounds as $round => $r) {
        $out[$round] = decide_playoff_share(max(0, $baseCents), (float) $r['pct'], 100.0, false)['amount'];
    }
    return $out;
}
