<?php

declare(strict_types=1);

const PP26DEV_COMMIT = 'b13448405413f1f16ae0f88676d47bbb5fc851ff';
const PP_CFP_FIELD_SIZE = 12;
const REFERENCE = __DIR__ . '/../reference/pp26dev';

foreach (glob(REFERENCE . '/lib/game/*.php') as $decider) {
    require_once $decider;
}

function money(int $cents): string
{
    return ($cents < 0 ? '-$' : '$') . number_format(abs($cents) / 100, 2);
}

function seasons(): array
{
    $seasons = [];
    foreach (glob(REFERENCE . '/setup/fixtures/season-*.json') as $file) {
        $season = json_decode(file_get_contents($file), true, flags: JSON_THROW_ON_ERROR);
        $seasons[$season['year']] = $season;
    }
    return $seasons;
}

function every_game(array $season): array
{
    $games = [];
    foreach ($season['games'] as $week => $weeksGames) {
        foreach ($weeksGames as $game) {
            $games[] = $game + ['week' => (int) $week, 'season_type' => 'regular'];
        }
    }
    foreach ($season['playoff'] as $game) {
        $games[] = $game + ['spread' => null, 'season_type' => 'postseason'];
    }
    return $games;
}

function randomizer(int $seed): Random\Randomizer
{
    return new Random\Randomizer(new Random\Engine\Mt19937($seed));
}

function pick(Random\Randomizer $random, array $choices): mixed
{
    return $choices[$random->getInt(0, count($choices) - 1)];
}

function record_battle_result(): array
{
    $cases = [];
    foreach (seasons() as $season) {
        foreach (every_game($season) as $game) {
            $spread = $game['spread'] === null ? null : (float) $game['spread'];
            $in = ['spread' => $spread, 'homePoints' => $game['home_points'],
                   'awayPoints' => $game['away_points'], 'home' => $game['home'],
                   'away' => $game['away']];
            $cases[] = ['in' => $in, 'out' => decide_battle_result(...$in)];
        }
    }
    $random = randomizer(11);
    for ($i = 0; $i < 400; $i++) {
        $spread = pick($random, [null, $random->getInt(-80, 80) / 2,
                                 $random->getInt(-400, 400) / 10]);
        $homePoints = $random->getInt(0, 60);
        $awayPoints = pick($random, [$homePoints, $random->getInt(0, 60),
                                     $homePoints + (int) ceil($spread ?? 0)]);
        $in = ['spread' => $spread, 'homePoints' => $homePoints,
               'awayPoints' => max(0, $awayPoints)];
        $cases[] = ['in' => $in, 'out' => decide_battle_result(...$in)];
    }
    return $cases;
}

function record_battle_settlement(): array
{
    $random = randomizer(12);
    $cases = [];
    for ($i = 0; $i < 600; $i++) {
        $battle = $random->getInt(0, 19) === 0 ? null : [
            'stake_cents' => pick($random, [100, 500, 1000, 5000,
                                            $random->getInt(1, 20000)]),
            'owner_a_id'  => 1,
            'owner_b_id'  => 2,
            'house_pct'   => pick($random, [0.0, 10.0, 12.5,
                                            $random->getInt(0, 10000) / 100]),
        ];
        $in = ['battle' => $battle, 'refund' => $random->getInt(0, 4) === 0,
               'winnerOwnerId' => pick($random, [1, 2, 3])];
        $cases[] = ['in' => $in, 'out' => decide_battle_settlement(...$in)];
    }
    return $cases;
}

function record_team_record(): array
{
    $cases = [];
    foreach (seasons() as $season) {
        $conferenceOf = array_column($season['teams'], 'conference', 'school');
        $games = every_game($season);
        foreach (array_keys($conferenceOf) as $team) {
            $played = array_values(array_filter($games, fn (array $game): bool
                => $game['home'] === $team || $game['away'] === $team));
            $completed = array_map('as_completed_game', $played);
            $cases[] = team_record_case($team, $completed, $conferenceOf);
            $lastWeek = array_keys(array_column($played, 'week'), $season['last_week']);
            foreach ($lastWeek as $index) {
                $completed[$index]['notes'] = "{$conferenceOf[$team]} Championship";
            }
            if ($lastWeek !== []) {
                $cases[] = team_record_case($team, $completed, $conferenceOf);
            }
        }
    }
    $random = randomizer(13);
    $conferenceOf = ['Alpha' => 'SEC', 'Beta' => 'SEC', 'Gamma' => 'ACC',
                     'Delta' => 'FBS Independents', 'Epsilon' => 'FBS Independents'];
    $everyone = [...array_keys($conferenceOf), 'Zeta FCS'];
    for ($i = 0; $i < 300; $i++) {
        $team = pick($random, array_keys($conferenceOf));
        $games = [];
        for ($g = $random->getInt(0, 6); $g > 0; $g--) {
            $opponent = pick($random, array_values(array_diff($everyone, [$team])));
            $atHome = $random->getInt(0, 1) === 1;
            [$home, $away] = $atHome ? [$team, $opponent] : [$opponent, $team];
            $homePoints = $random->getInt(0, 50);
            $games[] = [
                'home_team'   => $home,
                'away_team'   => $away,
                'home_points' => $homePoints,
                'away_points' => pick($random, [$homePoints, $random->getInt(0, 50)]),
                'spread'      => pick($random, [null, $random->getInt(-30, 30) / 2]),
                'season_type' => pick($random, ['regular', 'regular', 'postseason']),
                'notes'       => pick($random, ['', '', 'SEC Championship',
                                                'CHAMPIONSHIP GAME', 'Peach Bowl']),
            ];
        }
        $cases[] = team_record_case($team, $games, $conferenceOf);
    }
    return $cases;
}

function as_completed_game(array $game): array
{
    return [
        'home_team'   => $game['home'],
        'away_team'   => $game['away'],
        'home_points' => $game['home_points'],
        'away_points' => $game['away_points'],
        'spread'      => $game['spread'],
        'season_type' => $game['season_type'],
        'notes'       => $game['notes'] ?? '',
    ];
}

function team_record_case(string $team, array $games, array $conferenceOf): array
{
    $involved = [$team, ...array_column($games, 'home_team'),
                 ...array_column($games, 'away_team')];
    $confOf = [];
    foreach (array_unique($involved) as $name) {
        if (isset($conferenceOf[$name])) {
            $confOf[strtolower($name)] = $conferenceOf[$name];
        }
    }
    $in = ['team' => $team, 'games' => $games, 'confOf' => $confOf];
    return ['in' => $in, 'out' => decide_team_record(...$in)];
}

const PLAYOFF_PERCENT = ['bye' => 3.0, 'first_round' => 3.0, 'quarterfinal' => 6.0,
                         'semifinal' => 11.0, 'championship' => 30.0];

function record_playoff_slots(): array
{
    $random = randomizer(14);
    $cases = [];
    foreach (seasons() as $season) {
        $bracket = bracket_of($season);
        for ($played = 0; $played <= count($bracket); $played++) {
            $games = [...array_slice($bracket, 0, $played),
                      ...array_map('not_yet_played', array_slice($bracket, $played))];
            $cases[] = playoff_slots_case($games);
            $cases[] = playoff_slots_case(with_bowls_and_shuffled($random, $games));
        }
    }
    return $cases;
}

function bracket_of(array $season): array
{
    return array_map(fn (array $game): array => [
        'home'        => $game['home'],
        'away'        => $game['away'],
        'home_points' => $game['home_points'],
        'away_points' => $game['away_points'],
        'completed'   => true,
        'notes'       => $game['notes'],
    ], $season['playoff']);
}

function not_yet_played(array $game): array
{
    return ['completed' => false, 'home_points' => null, 'away_points' => null] + $game;
}

function with_bowls_and_shuffled(Random\Randomizer $random, array $games): array
{
    $bowls = [['Peach Bowl', true], ['Gator Bowl', true],
              ['College Football Playoff Bye Week Special', true],
              ['Rose Bowl Game', false], ['', true]];
    foreach ($bowls as [$notes, $completed]) {
        $games[] = ['home' => 'Bowl Home', 'away' => 'Bowl Away', 'home_points' => 21,
                    'away_points' => 14, 'completed' => $completed, 'notes' => $notes];
    }
    if ($random->getInt(0, 1) === 0) {
        $games = array_map(fn (array $game): array
            => ['notes' => strtolower($game['notes'])] + $game, $games);
    }
    return $random->shuffleArray($games);
}

function playoff_slots_case(array $games): array
{
    $in = ['games' => $games];
    return ['in' => $in, 'out' => decide_playoff_slots(...$in)];
}

function record_playoff_share(): array
{
    $random = randomizer(15);
    $cases = [];
    foreach (seasons() as $season) {
        $slots = decide_playoff_slots(bracket_of($season))['slots'];
        if ($slots === []) {
            continue;
        }
        for ($run = 0; $run < 60; $run++) {
            $remainingPool = pick($random, [60000, 100000, $random->getInt(0, 500000)]);
            $unrecordedPct = 100.0;
            $houseOwnedChance = pick($random, [0, 10, 50, 100]);
            foreach ($slots as $slot) {
                $in = ['remainingPool' => $remainingPool,
                       'thisPct' => PLAYOFF_PERCENT[$slot['round']],
                       'unrecordedPct' => $unrecordedPct,
                       'forfeited' => $random->getInt(1, 100) <= $houseOwnedChance];
                $out = decide_playoff_share(...$in);
                $cases[] = ['in' => $in, 'out' => $out];
                $remainingPool = $out['remainder_after'];
                $unrecordedPct -= $in['thisPct'];
            }
        }
    }
    return $cases;
}

function record_payout_estimates(): array
{
    $random = randomizer(16);
    $rounds = array_map(fn (float $pct): array => ['pct' => $pct], PLAYOFF_PERCENT);
    $cases = [];
    for ($i = 0; $i < 300; $i++) {
        $in = ['baseCents' => pick($random, [0, 60000, $random->getInt(0, 1000000)]),
               'rounds' => $rounds];
        $cases[] = ['in' => $in, 'out' => decide_payout_estimates(...$in)];
    }
    return $cases;
}

function write_golden(string $decider, array $cases): void
{
    $flags = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION
           | JSON_THROW_ON_ERROR;
    $lines = array_map(fn (array $case): string => json_encode($case, $flags), $cases);
    $header = json_encode(['decider' => $decider, 'pp26dev' => PP26DEV_COMMIT], $flags);
    file_put_contents(__DIR__ . "/{$decider}.json",
        substr($header, 0, -1) . ",\"cases\":[\n" . implode(",\n", $lines) . "\n]}\n");
    printf("%-28s %5d cases\n", $decider, count($cases));
}

$recorders = [
    'decide_battle_result'     => 'record_battle_result',
    'decide_battle_settlement' => 'record_battle_settlement',
    'decide_team_record'       => 'record_team_record',
    'decide_playoff_slots'     => 'record_playoff_slots',
    'decide_playoff_share'     => 'record_playoff_share',
    'decide_payout_estimates'  => 'record_payout_estimates',
];
$wanted = array_slice($argv, 1) ?: array_keys($recorders);
foreach ($wanted as $decider) {
    write_golden($decider, $recorders[$decider]());
}
