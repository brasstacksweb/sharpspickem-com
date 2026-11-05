<?php

declare(strict_types=1);

const PP26DEV_COMMIT = 'b13448405413f1f16ae0f88676d47bbb5fc851ff';
const PP_CFP_FIELD_SIZE = 12;
const REFERENCE = __DIR__ . '/../reference/pp26dev';

date_default_timezone_set('UTC');

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
                      ...array_map('in_progress', array_slice($bracket, $played, 1)),
                      ...array_map('not_yet_played', array_slice($bracket, $played + 1))];
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

function in_progress(array $game): array
{
    return ['completed' => false] + $game;
}

function not_yet_played(array $game): array
{
    return ['completed' => false, 'home_points' => null, 'away_points' => null] + $game;
}

function with_bowls_and_shuffled(Random\Randomizer $random, array $games): array
{
    $bowls = [['Peach Bowl', true], ['Gator Bowl', true],
              ['College Football Playoff Bye Week Special', true],
              ['Rose Bowl Game', false], ['', true], ['National Bowl Showcase', true],
              ['First Round of the Bowl Season Quarterfinal Classic', true]];
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

function recorded(callable $decider, array $inputs): array
{
    return array_map(fn (array $in): array => ['in' => $in, 'out' => $decider(...$in)],
                     $inputs);
}

function generated(int $seed, int $count, callable $generate): array
{
    $random = randomizer($seed);
    return array_map(fn (): array => $generate($random), range(1, $count));
}

function owner_holding(Random\Randomizer $random): array
{
    $stake = pick($random, [100, 500, 1000]);
    $maxTeams = $random->getInt(1, 8);
    $teamsHeld = $random->getInt(0, $maxTeams);
    return [
        'funds'            => pick($random, [0, $random->getInt(0, 40) * 100,
                                             $random->getInt(0, 10000)]),
        'stake'            => $stake,
        'max_teams'        => $maxTeams,
        'teams_held'       => $teamsHeld,
        'extra_games'      => pick($random, [0, 0, 1, 2]),
        'escrow'           => pick($random, [0, $stake,
                                             $random->getInt(0, $teamsHeld) * $stake,
                                             $random->getInt(0, 5000)]),
        'battles_possible' => $random->getInt(0, 4) > 0,
    ];
}

function record_reserve_for(): array
{
    return recorded('reserve_for', generated(17, 300, fn ($random): array => [
        'teams'           => $random->getInt(0, 8),
        'stakeCents'      => pick($random, [0, 100, 500, $random->getInt(1, 5000)]),
        'extraGames'      => pick($random, [0, 0, 1, 2]),
        'battlesPossible' => $random->getInt(0, 3) > 0,
    ]));
}

function record_reserve_headroom(): array
{
    $spending = generated(18, 1500, fn ($random): array => [
        's' => owner_holding($random) + [
            'teams_gained' => pick($random, [0, 1, 1, $random->getInt(0, 4)]),
            'cash_out'     => pick($random, [0, $random->getInt(0, 30) * 100,
                                             $random->getInt(0, 5000)]),
        ],
    ]);
    return recorded('decide_reserve_headroom', $spending);
}

function record_margin_call(): array
{
    return recorded('decide_margin_call', generated(19, 1000, fn ($random): array => [
        's' => owner_holding($random),
    ]));
}

const BUYBACK_STAGES = ['open', 'top12', 'closed'];

function rank_position(Random\Randomizer $random): ?int
{
    return pick($random, [null, $random->getInt(1, 25), 12, 13]);
}

function record_house_will_buy(): array
{
    $inputs = [];
    foreach (BUYBACK_STAGES as $stage) {
        foreach ([null, ...range(1, 25)] as $rankPos) {
            $inputs[] = ['stage' => $stage, 'rankPos' => $rankPos];
        }
    }
    return recorded('house_will_buy', $inputs);
}

function record_sale(): array
{
    return recorded('decide_sale', generated(20, 1500, fn ($random): array => [
        'team'         => pick($random, [null, seller($random->getInt(0, 9000)),
                                         seller(0)]),
        'stage'        => pick($random, BUYBACK_STAGES),
        'marketValue'  => $random->getInt(1, 60) * 100,
        'houseBalance' => pick($random, [0, $random->getInt(0, 80) * 100, 1000000]),
        'rankPos'      => rank_position($random),
    ]));
}

function seller(int $basis): array
{
    return ['name' => 'Alpha', 'acquired_price_cents' => $basis];
}

function record_buyback_forecast(): array
{
    $utc = new DateTimeZone('UTC');
    $cases = generated(21, 800, function ($random) use ($utc): array {
        $now = $random->getInt(1785000000, 1800000000);
        $expectedOn = date('Y-m-d', $now + $random->getInt(-20, 60) * 86400);
        return ['stage' => pick($random, BUYBACK_STAGES),
                'expectedOn' => pick($random, [$expectedOn, $expectedOn, '', null]),
                'nowTs' => $now, 'tz' => $utc];
    });
    return array_map(fn (array $case): array => ['in' => ['tz' => 'UTC'] + $case['in']]
        + $case, recorded('decide_buyback_forecast', $cases));
}

function record_calendar_warnings(): array
{
    $setups = generated(22, 1000, function ($random): array {
        $narrows = pick($random, ['', league_date($random)]);
        $closes = pick($random, ['', league_date($random)]);
        $today = pick($random, [league_date($random), $narrows ?: $closes, $closes]);
        return ['s' => [
            'narrows'        => $narrows,
            'closes'         => $closes,
            'today'          => $today ?: league_date($random),
            'championships'  => pick($random, [null, league_date($random),
                                               $closes ?: null]),
            'season_started' => $random->getInt(0, 1) === 1,
        ]];
    });
    return recorded('decide_calendar_warnings', $setups);
}

function league_date(Random\Randomizer $random): string
{
    return date('Y-m-d', 1787000000 + $random->getInt(0, 120) * 86400);
}

const HOUR = 3600;
const DAY = 86400;

function record_game_state(): array
{
    return recorded('game_state', generated(23, 600, fn ($random): array => [
        'start'     => pick($random, [null, 1760000000]),
        'completed' => $random->getInt(0, 1) === 1,
        'now'       => 1760000000 + pick($random, [0, -1, 1, 8 * HOUR, 8 * HOUR - 1,
                                                   $random->getInt(-DAY, DAY)]),
    ]));
}

function record_availability(): array
{
    $random = randomizer(24);
    $cases = [];
    foreach (seasons() as $season) {
        $games = every_game($season);
        $teams = array_column($season['teams'], 'school');
        $openings = openings($games);
        $finishes = [];
        foreach ($games as $index => $game) {
            $finishes[$index] = $random->getInt(1, 20) === 1
                ? null : $game['kickoff'] + $random->getInt(3 * HOUR, 4 * HOUR);
        }
        $playoff = array_values(array_filter($games, fn (array $game): bool
            => $game['season_type'] === 'postseason'));
        for ($moment = 0; $moment < 50; $moment++) {
            $game = pick($random, $moment < 10 && $playoff !== [] ? $playoff : $games);
            $now = $game['kickoff'] + pick($random, [
                -30 * 60 - 1, -30 * 60, -30 * 60 + 1, 0, -1, 2 * HOUR, 4 * HOUR,
                8 * HOUR - 1, 8 * HOUR, $random->getInt(-3 * DAY, 3 * DAY),
                pick($random, $openings) - $game['kickoff'],
            ]);
            $snapshot = [
                'teams'     => board($random, $teams, $games, $now),
                'opened_at' => pick($random, [latest_opening($openings, $now),
                                              latest_opening($openings, $now), null,
                                              $game['kickoff']]),
                'now'       => $now,
                'lead'      => pick($random, [1800, 1800, 0, 3600]),
            ];
            $input = ['games' => array_values(array_filter(array_map(
                fn (array $game, int $index): ?array
                    => game_near($game, $finishes[$index], $now, $season['last_week']),
                $games, array_keys($games))))];
            if ($random->getInt(1, 4) === 1) {
                $input['games'][] = ['home' => pick($random, $teams),
                                     'away' => 'Unscheduled', 'start' => null,
                                     'completed' => false, 'week' => 1,
                                     'season_type' => 'regular'];
            }
            $in = ['snapshot' => $snapshot, 'input' => $input];
            $cases[] = ['in' => $in, 'out' => decide_availability(...$in)];
        }
    }
    return $cases;
}

function openings(array $games): array
{
    $lastKickoffOfWeek = [];
    foreach ($games as $game) {
        if ($game['season_type'] === 'regular') {
            $week = $game['week'];
            $lastKickoffOfWeek[$week] = max($lastKickoffOfWeek[$week] ?? 0,
                                            $game['kickoff']);
        }
    }
    return array_values(array_map(fn (int $kickoff): int => $kickoff + 36 * HOUR,
                                  $lastKickoffOfWeek));
}

function latest_opening(array $openings, int $now): ?int
{
    $opened = array_filter($openings, fn (int $opening): bool => $opening <= $now);
    return $opened === [] ? null : max($opened);
}

function board(Random\Randomizer $random, array $teams, array $games, int $now): array
{
    $playingNow = [];
    foreach ($games as $game) {
        if (abs($game['kickoff'] - $now) < 6 * HOUR) {
            $playingNow[] = $game['home'];
            $playingNow[] = $game['away'];
        }
    }
    $sampled = array_slice($random->shuffleArray($teams), 0, 20);
    $board = array_values(array_unique([...array_slice($playingNow, 0, 10),
                                        ...$sampled]));
    return array_map(fn (string $team, int $id): array => [
        'id'              => $id + 1,
        'name'            => $team,
        'has_live_battle' => $random->getInt(1, 10) === 1,
    ], $board, array_keys($board));
}

function game_near(array $game, ?int $finishesAt, int $now, int $lastWeek): ?array
{
    $endOfTheRegularSeason = $game['season_type'] === 'regular'
        && $game['week'] === $lastWeek && $game['kickoff'] <= $now;
    if (abs($game['kickoff'] - $now) > 8 * DAY && !$endOfTheRegularSeason) {
        return null;
    }
    return [
        'home'        => $game['home'],
        'away'        => $game['away'],
        'start'       => $game['kickoff'],
        'completed'   => $finishesAt !== null && $finishesAt <= $now,
        'week'        => $game['week'],
        'season_type' => $game['season_type'],
    ];
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
    'reserve_for'              => 'record_reserve_for',
    'decide_reserve_headroom'  => 'record_reserve_headroom',
    'decide_margin_call'       => 'record_margin_call',
    'house_will_buy'           => 'record_house_will_buy',
    'decide_sale'              => 'record_sale',
    'decide_buyback_forecast'  => 'record_buyback_forecast',
    'decide_calendar_warnings' => 'record_calendar_warnings',
    'game_state'               => 'record_game_state',
    'decide_availability'      => 'record_availability',
];
$wanted = array_slice($argv, 1) ?: array_keys($recorders);
foreach ($wanted as $decider) {
    write_golden($decider, $recorders[$decider]());
}
