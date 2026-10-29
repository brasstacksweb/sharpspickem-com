<?php

// Pure decider for selling a team back to the House — no DB, no IO. The House balance
// passed in is an optimistic read; the AUTHORITATIVE guard is in sale_to_house(), under a
// lock.
//
// $rankPos — position in the poll currently pricing the league, null outside the Top 25.
// Two of §8's rules read it: an unranked team is never bought, and once the committee's
// rankings are out only the playoff field is.
//
// $stage — house_buyback_stage(). Checked here as well as at queue time, because a poll or
// the bracket can land BETWEEN an owner queueing a sale and the window closing on it, and
// §8 prices that sale at the moment it would settle.
//
// IT DELIBERATELY DOES NOT DECIDE AVAILABILITY (§6). `false` here means "no, ever", and the
// caller closes the order out; an unavailable team is "not yet", and §6 rolls the order
// forward. One boolean cannot carry both, so that fork lives in the wrapper.
//
// Returns ['ok'=>true, 'mv','basis']  |  ['ok'=>false,'code','error'].
// 'basis' is the seller's own cost, carried out so the caller can record it on the
// disposal — the team row holding it is cleared by the same operation. It is NOT a price:
// §8 pays Market Value in full, so 'mv' is what the owner receives.

/**
 * WILL THE HOUSE BUY A TEAM OF THIS RANK AT THIS STAGE? (§8.) The ONE place the staging is
 * arithmetic — decide_sale() asks it, and so does the settlement pass, which needs the same
 * answer a beat earlier to tell a permanent refusal from a timing block. Written out twice
 * and a mutation of the 1–12 boundary survives, because the second copy catches it.
 *
 * $rankPos: position in the poll currently pricing the league, null when unranked.
 */
function house_will_buy(string $stage, ?int $rankPos): bool
{
    if ($stage === 'closed' || $rankPos === null) {
        return false;
    }
    return $stage !== 'top12' || $rankPos <= PP_CFP_FIELD_SIZE;
}

/**
 * WHICH STAGE IS COMING, AND EXACTLY WHEN. (§8.)
 *
 * It decides nothing — house_buyback_stage() is the authority — but it is not a guess:
 * both read the SAME two dates, so the count states when the boundary WILL fire.
 *
 * $expectedOn is the boundary date for whichever stage comes next — 'YYYY-MM-DD', or ''
 * for a league still in setup — which the caller picks from the current stage.
 *
 * GOES QUIET RATHER THAN COUNTING PAST ZERO: "in -3 days" is worse than silence.
 *
 * DAYS ARE LEAGUE-LOCAL CALENDAR DAYS, which is why the zone is an argument. Both ends are
 * anchored to midnight in $tz before the subtraction, so a shift the night the clocks change
 * still reads as one day away. Nothing in here reads a clock of its own.
 *
 * Returns null when there is nothing to warn about, else
 * ['next_stage' => 'top12'|'closed', 'expected_on' => 'YYYY-MM-DD', 'days' => int >= 0].
 */
function decide_buyback_forecast(string $stage, ?string $expectedOn, int $nowTs, DateTimeZone $tz): ?array
{
    // Nothing narrows after the House has closed — §8 has no fourth stage.
    if ($stage === 'closed' || $expectedOn === null || $expectedOn === '') {
        return null;
    }
    // THE ROUND TRIP IS THE VALIDATION: createFromFormat rolls '2026-02-31' to March 3 and
    // says nothing, so comparing the reparsed date back is the only refusal there is.
    $target = DateTimeImmutable::createFromFormat('!Y-m-d', $expectedOn, $tz);
    if ($target === false || $target->format('Y-m-d') !== $expectedOn) {
        return null;
    }
    // "Today" where the league lives, not where the server does.
    $today = (new DateTimeImmutable('@' . $nowTs))->setTimezone($tz)->setTime(0, 0, 0);
    $diff = $today->diff($target);
    if ($diff->invert === 1) {
        return null;
    }

    return [
           'next_stage'  => $stage === 'open' ? 'top12' : 'closed',
           'expected_on' => $expectedOn,
           'days'        => (int) $diff->days,
       ];
}

function decide_sale(
    ?array $team,
    string $stage,
    int $marketValue,
    int $houseBalance,
    ?int $rankPos
): array {
    // §8's staging is the ONLY thing that stops the House buying, and nothing may be added
    // beside it — in particular no Commissioner suspension. The rulebook grants no such
    // power, and §16 is the amendment procedure.
    if ($stage === 'closed') {
        return ['ok' => false, 'code' => 400, 'error' =>
                   'The House stopped buying teams for the season on the date the Commissioner set '
                   . 'before the draft (§8). You can still trade with another owner.'];
    }
    if ($team === null) {
        return ['ok' => false, 'code' => 400, 'error' => 'You do not own that team'];
    }
    // §5 (Q2): the House only buys teams it has a price for. An unranked team is free to
    // add and free to drop, and becomes sellable the moment it enters either Top 25.
    if ($rankPos === null) {
        return ['ok' => false, 'code' => 400, 'error' =>
                   ($team['name'] ?? 'That team') . ' is unranked — the House only buys teams in the AP or CFP Top 25. Drop it instead (free), or hold it until it is ranked.'];
    }
    // §8's two boundaries. The middle stage names the RANK, because that is what the owner
    // can check; the closed stage does not, because no rank would have helped.
    if (!house_will_buy($stage, $rankPos)) {
        return ['ok' => false, 'code' => 400, 'error' => $stage === 'closed'
                   ? ($team['name'] ?? 'That team') . ' cannot be sold — the House stopped buying teams '
                     . 'for the season on the date the Commissioner set before the draft (§8). You can '
                     . 'still trade with another owner, or drop it for free.'
                   : ($team['name'] ?? 'That team') . ' is ranked #' . $rankPos . ' — the House now only '
                     . 'buys teams in the top ' . PP_CFP_FIELD_SIZE . ' (§8). You can still trade with '
                     . 'another owner, or drop it for free.'];
    }

    // The same operation clears the team row holding this, so it is the last moment it can
    // be read.
    $basis = ($team['acquired_price_cents'] ?? null) !== null ? (int)$team['acquired_price_cents'] : 0;

    if ($houseBalance < $marketValue) {
        return ['ok' => false, 'code' => 400, 'error' => 'The House Account cannot cover this sale right now'];
    }

    return ['ok' => true, 'mv' => $marketValue, 'basis' => $basis];
}
