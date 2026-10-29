<?php

// Pure decider for which playoff payouts a finished bracket has earned — no DB, no IO.
//
// §12 pays a fixed percentage to "the owner of the winning team" for every CFP game, plus a
// share to each first-round bye. No judgment is involved: the winner is whoever scored more.
//
// "THE OWNER OF RECORD" IS READ AT THE MOMENT THE SLOT IS WON, and it genuinely changes
// between rounds — Q18 removed the postseason freeze, so teams trade through the
// Championship Game.
//
// Q14: an unrecorded slot is treated as still OWED and held back from the later rounds, so
// one forgotten bye makes every later round underpay AND leaves the pool short of $0.00.
//
// ROUNDS COME FROM CFBD'S OWN `notes` STRING, never from dates or ordering — a CFP
// quarterfinal and the Gator Bowl are both postseason games in the same week. An
// unrecognised label records nothing rather than paying the wrong person.
//
// BYES ARE DERIVED, not published: a quarterfinalist who played no first-round game had one.

/**
 * The substring CFBD publishes in `notes` => the round key it means. Walked in order, first
 * match wins, and an unrecognised label yields NO slot rather than a guess.
 *
 * `bye` is absent on purpose — CFBD never publishes one; it is derived below.
 */
const PP_CFBD_ROUND_LABELS = [
    'First Round' => 'first_round',
    'Quarter'     => 'quarterfinal',
    'Semifin'     => 'semifinal',
    'National'    => 'championship',
];

/**
 * Which CFP round is this game, read from CFBD's own `notes` — or null for a bowl, an
 * unrecognised label, or anything else in the postseason.
 *
 * ONE MATCHER for two callers that must never disagree: this decides who is PAID, and
 * decide_playoff_bracket() decides what an owner is SHOWN.
 */
function playoff_round_from_notes(?string $notes): ?string
{
    $notes = (string) $notes;
    if (stripos($notes, 'playoff') === false) {
        return null;                    // a bowl, not the CFP
    }
    foreach (PP_CFBD_ROUND_LABELS as $needle => $key) {
        if (stripos($notes, $needle) !== false) {
            return $key;
        }
    }
    return null;
}

/**
 * $games: [ ['home','away','home_points','away_points','completed','notes'], … ] —
 *         everything cached for the postseason, bowls included.
 *
 * Returns ['slots' => [ ['round','team','opponent','detail'], … ],
 *          'skipped_incomplete' => int]  in payout order (byes first, championship last).
 */
function decide_playoff_slots(array $games): array
{
    $rounds = [];                       // round => [ [home, away, hp, ap, notes], … ]
    $skipped = 0;

    foreach ($games as $g) {
        $round = playoff_round_from_notes($g['notes'] ?? null);
        if ($round === null) {
            continue;
        }
        // Counted so the caller can say "waiting on 3 games" rather than doing nothing.
        if (empty($g['completed']) || $g['home_points'] === null || $g['away_points'] === null) {
            $skipped++;
            continue;
        }
        $rounds[$round][] = $g;
    }

    // Who appeared in the first round, so the byes can be worked out.
    $playedFirstRound = [];
    foreach ($rounds['first_round'] ?? [] as $g) {
        $playedFirstRound[strtolower((string)$g['home'])] = true;
        $playedFirstRound[strtolower((string)$g['away'])] = true;
    }

    $slots = [];

    // Byes first — the earliest-paid round, and under Q14 the recording order decides how a
    // forfeited share reaches the rounds after it.
    foreach ($rounds['quarterfinal'] ?? [] as $g) {
        foreach ([[$g['home'], $g['away']], [$g['away'], $g['home']]] as [$team, $opp]) {
            if (!isset($playedFirstRound[strtolower((string)$team)])) {
                $slots[] = [
                    'round'    => 'bye',
                    'team'     => (string)$team,
                    'opponent' => (string)$opp,
                    'detail'   => 'First-round bye',
                ];
            }
        }
    }

    foreach (['first_round', 'quarterfinal', 'semifinal', 'championship'] as $round) {
        foreach ($rounds[$round] ?? [] as $g) {
            $homeWon = (int)$g['home_points'] > (int)$g['away_points'];
            $slots[] = [
                'round'    => $round,
                'team'     => (string)($homeWon ? $g['home'] : $g['away']),
                'opponent' => (string)($homeWon ? $g['away'] : $g['home']),
                'detail'   => sprintf('%s %d–%d %s', $g['away'], (int)$g['away_points'],
                    (int)$g['home_points'], $g['home']),
            ];
        }
    }

    return ['slots' => $slots, 'skipped_incomplete' => $skipped];
}

/**
 * The bracket as something to LOOK at — every CFP game in round order, played or not.
 *
 * The sibling of decide_playoff_slots(), which answers "what has been WON" and so drops an
 * unplayed game. A view has to show exactly those.
 *
 * ROUNDS COME FROM `notes`, NEVER FROM `week`: the postseason restarts games.week at 1, so
 * grouping on it merges the bracket's first round with the opening Saturday of the season.
 *
 * BYES ARE DERIVED as decide_playoff_slots() derives them, returned separately because §12
 * pays a bye with no game played for it, and withheld until every first-round game is FINAL.
 *
 * $games: cached_postseason_games() — bowls included, filtered here.
 *
 * Returns [ 'rounds' => [ ['key','label','games' => [ ['home','away','home_points',
 *           'away_points','final','kickoff_at','notes'], … ] ], … ] in bracket order,
 *           'byes' => [team, …], 'total' => int, 'final' => int ]
 */
function decide_playoff_bracket(array $games): array
{
    $byRound = [];
    $total = 0;
    $final = 0;

    foreach ($games as $g) {
        $round = playoff_round_from_notes($g['notes'] ?? null);
        if ($round === null) {
            continue;
        }
        // A score is not enough: CFBD carries points on a game in progress. `completed` is
        // the flag §6's game-lock trusts, for the same reason.
        $isFinal = !empty($g['completed'])
            && ($g['home_points'] ?? null) !== null && ($g['away_points'] ?? null) !== null;

        $byRound[$round][] = [
            'home'         => (string) $g['home'],
            'away'         => (string) $g['away'],
            'home_points'  => $isFinal ? (int) $g['home_points'] : null,
            'away_points'  => $isFinal ? (int) $g['away_points'] : null,
            'final'        => $isFinal,
            'kickoff_at'   => $g['kickoff_at'] ?? null,
            'notes'        => (string) ($g['notes'] ?? ''),
        ];
        $total++;
        $final += $isFinal ? 1 : 0;
    }

    // A BYE IS ONLY KNOWABLE ONCE EVERY FIRST-ROUND GAME IS FINAL, not merely scheduled:
    // before then a quarterfinal row need not name a real opponent, and publishing it as a
    // bye announces a payout to somebody who has not earned one.
    $firstRound = $byRound['first_round'] ?? [];
    $allPlayed = $firstRound !== [];
    $playedFirstRound = [];
    foreach ($firstRound as $g) {
        $allPlayed = $allPlayed && $g['final'];
        $playedFirstRound[strtolower($g['home'])] = true;
        $playedFirstRound[strtolower($g['away'])] = true;
    }
    $byes = [];
    if ($allPlayed) {
        foreach ($byRound['quarterfinal'] ?? [] as $g) {
            foreach ([$g['home'], $g['away']] as $team) {
                if (!isset($playedFirstRound[strtolower($team)])) {
                    $byes[] = $team;
                }
            }
        }
    }

    // Bracket order, from the round vocabulary rather than a second list of names here.
    $rounds = [];
    foreach (['first_round', 'quarterfinal', 'semifinal', 'championship'] as $key) {
        if (empty($byRound[$key])) {
            continue;
        }
        // Earliest kickoff first, so a half-played round reads in playing order.
        usort($byRound[$key], static fn (array $a, array $b): int
            => strcmp((string) $a['kickoff_at'], (string) $b['kickoff_at']));
        $rounds[] = [
            'key'   => $key,
            'label' => PP_PLAYOFF_ROUNDS[$key]['label'] ?? $key,
            'games' => $byRound[$key],
        ];
    }

    return ['rounds' => $rounds, 'byes' => $byes, 'total' => $total, 'final' => $final];
}
