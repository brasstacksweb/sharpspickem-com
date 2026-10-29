<?php

// The §11 Battle reserve, in one place — no DB, no IO.
//
// §11 promises: "The only way to drop below the reserve is by losing Battles, which nobody
// chooses to do". That sentence is the specification, and it is only true if EVERY acting
// route — bid, free add, trade, stake raise — refuses to take an owner below the line. So
// the arithmetic lives HERE rather than inside one route's affordability check.

/**
 * One stake per team held — the reserve itself, and the ONE place it is arithmetic. Margin
 * Call and every acting route ask this function.
 *
 * `$extraGames` is Q21: the reserve covers every GAME a held team plays this week, counted
 * BEYOND one per team, so zero is the ordinary `teams × stake`. A team on a bye still
 * reserves one — "never below one stake per team" — and this touches only the 0.1% of
 * team-weeks carrying two games (three per season in both 2024 and 2025).
 */
function reserve_for(int $teams, int $stakeCents, int $extraGames = 0, bool $battlesPossible = true): int
{
    // THE RESERVE LAPSES WHEN THE FOOTBALL DOES: §11 puts no Battles in bowl games or the
    // Playoff, and Q18 leaves the market open through the Championship, so without this an
    // owner spends the whole postseason in Margin Call over wagers the rules forbid.
    //
    // The CALLER decides — the schedule is IO — and it DEFAULTS TRUE, so a call site that
    // forgets keeps reserving rather than releasing every reserve in the league.
    if (!$battlesPossible) {
        return 0;
    }
    return ($teams + $extraGames) * $stakeCents;
}

/**
 * How much an owner could still spend and remain inside §11.
 *
 *     held     = reserve − escrow already covering live Battles
 *     headroom = funds − cash_out − held
 *
 * `teams_gained` is a FORECAST, capped at `max_teams` — reserving for ten queued adds when
 * only five can land locks up money for teams that cannot exist.
 *
 * It does NOT net off pending releases, so a drop and an add queued in one window is
 * refused though the swap is even. The queue-time check only has to be SAFE; the
 * settlement re-check guarantees the outcome.
 *
 * $s: funds, stake, max_teams, teams_held, teams_gained, cash_out, extra_games, escrow,
 *     battles_possible (the last three optional; `battles_possible` defaults TRUE so a
 *     caller that does not ask keeps reserving — see reserve_for())
 * Returns ['ok','funds','cash_out','teams_after','extra_games','reserve','escrow',
 *          'held_cents','headroom'].
 */
function decide_reserve_headroom(array $s): array
{
    $teamsAfter = min((int) $s['max_teams'], (int) $s['teams_held'] + (int) $s['teams_gained']);
    // Q21: extra games are NOT capped with the team count — a team already held playing
    // twice is a fact about the schedule, not a forecast.
    $extraGames = (int) ($s['extra_games'] ?? 0);
    $reserve    = reserve_for($teamsAfter, (int) $s['stake'], $extraGames,
        (bool) ($s['battles_possible'] ?? true));

    // ESCROW IS CREDITED, exactly as decide_margin_call() credits it: a stake taken for a
    // live Battle has already left Available Funds, and holding a second against the same
    // game makes a $5 wager cost $10 of spendable cash while Margin Call reports the owner
    // as fine. The two halves of §11 must agree.
    //
    // Capped at the reserve here; the CALLER caps it at one stake per team held — see
    // owner_battle_escrow_cents(), the single definition of that credit.
    $escrow   = max(0, min((int) ($s['escrow'] ?? 0), $reserve));
    $held     = $reserve - $escrow;                 // what still has to stay in cash
    $headroom = (int) $s['funds'] - (int) $s['cash_out'] - $held;

    return [
           'ok'          => $headroom >= 0,
           'funds'       => (int) $s['funds'],
           'cash_out'    => (int) $s['cash_out'],
           'teams_after' => $teamsAfter,
           'extra_games' => $extraGames,
           'reserve'     => $reserve,
           'escrow'      => $escrow,
           // What still has to sit in Available Funds — the dashboard's "Held for Battle
           // Stakes" figure.
           'held_cents'  => $held,
           'headroom'    => $headroom,
       ];
}

/** "4 teams" / "1 team" — the reserve is explained in these terms everywhere. */
function reserve_teams_label(int $teams): string
{
    return $teams . ' team' . ($teams === 1 ? '' : 's');
}

/**
 * IS THIS OWNER UNDER MARGIN CALL? (§11, Q20 ruled by Spencer.) Pure.
 *
 * THERE IS NO SOLVENCY SWEEP — nothing is ever sold or dropped on an owner's behalf, which
 * is also what closes Q20: with no automatic liquidation nothing can reach the House after
 * §8 shuts the buybacks, so §8's staging binds everything there is.
 *
 * Being short is a STATE, not an action: an owner may not increase exposure until it clears.
 * Everything that reduces exposure or brings money in stays open, and those are the ways out.
 *
 * ESCROW COUNTS, or creating a Battle would put both owners into Margin Call the instant
 * §11 compelled them into it. Capped at one per team held: a team can play twice (Q21) and
 * an `accepted` Battle whose game never completed keeps its stake for ever, either of which
 * would credit more than the owner holds teams.
 *
 * DERIVED ON READ, never stored — a flag would need a job to write it and could go stale,
 * which is the shape §6's availability was rewritten to escape.
 *
 * $s: funds, escrow, stake, teams_held, extra_games, battles_possible
 *     (the last two optional; `battles_possible` defaults TRUE — see reserve_for())
 * Returns ['in_call','funds','escrow','required','short'].
 */
function decide_margin_call(array $s): array
{
    $required = reserve_for((int) $s['teams_held'], (int) $s['stake'], (int) ($s['extra_games'] ?? 0),
        (bool) ($s['battles_possible'] ?? true));
    $covered  = (int) $s['funds'] + (int) $s['escrow'];
    return [
           'in_call'  => $covered < $required,
           'funds'    => (int) $s['funds'],
           'escrow'   => (int) $s['escrow'],
           'required' => $required,
           'short'    => max(0, $required - $covered),
       ];
}
