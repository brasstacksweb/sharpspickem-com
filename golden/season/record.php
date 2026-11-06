<?php

declare(strict_types=1);

$pp26dev = getenv('PP26DEV') ?: getenv('HOME') . '/Projects/plassman-pickem';
require $pp26dev . '/setup/simulator.php';

$options = getopt('', ['year::', 'seed::', 'weeks::', 'twice']);
$year = (int) ($options['year'] ?? 2024);
$seed = (int) ($options['seed'] ?? 1);
$weeks = (int) ($options['weeks'] ?? 99);
$twice = isset($options['twice']);

final class Trace
{
    public ?int $leagueId = null;
    public array $events = [];
    public array $seen = [];
    private array $lastFacts = [];
    private array $settledOpenings = [];
    private array $battlesSeen = [];
    private int $ownerMark = 0;
    private int $houseMark = 0;
    private int $pollMark = 0;
    private int $firstKickoff;

    public function __construct(array $fixture)
    {
        $kickoffs = [];
        foreach ($fixture['games'] as $games) {
            foreach ($games as $game) {
                $kickoffs[] = (int) $game['kickoff'];
            }
        }
        $this->firstKickoff = min($kickoffs);
    }

    public function begin(int $leagueId): void
    {
        if ($this->leagueId !== null) {
            return;
        }
        $this->leagueId = $leagueId;
        $this->events[] = ['event' => 'league'] + league_setup($leagueId)
                        + ['at' => $this->fixtureNow()];
        $this->settle('setup');
    }

    public function settle(string $event, array $detail = [], ?int $at = null): void
    {
        if ($this->leagueId === null) {
            return;
        }
        $at ??= $this->fixtureNow();
        $this->events[] = ['event' => $event, 'at' => $at] + $detail
            + ['polls' => $this->newPolls(), 'ledger' => $this->newLedgerRows()]
            + $this->changedFacts() + $this->newBattles();
        foreach (NUMBERED as $kind => $table) {
            $ids = db()->prepare("SELECT id FROM {$table} WHERE league_id = ?");
            $ids->execute([$this->leagueId]);
            foreach ($ids->fetchAll(PDO::FETCH_COLUMN) as $id) {
                $this->seen[$kind][(int) $id] = true;
            }
        }
    }

    public function fixtureNow(): int
    {
        return time() - $this->shift();
    }

    private function shift(): int
    {
        $firstKickoff = (int) db()->query(
            'SELECT MIN(UNIX_TIMESTAMP(kickoff_at)) FROM games')->fetchColumn();
        return $firstKickoff - $this->firstKickoff;
    }

    private function newBattles(): array
    {
        $battles = db()->prepare('SELECT b.id, b.week, home.name AS home,
                                         away.name AS away
                                    FROM battles b
                                    JOIN teams home ON home.id = b.team_a_id
                                    JOIN teams away ON away.id = b.team_b_id
                                   WHERE b.league_id = ? ORDER BY b.id');
        $battles->execute([$this->leagueId]);
        $new = [];
        foreach ($battles->fetchAll() as $battle) {
            if (!isset($this->battlesSeen[$battle['id']])) {
                $this->battlesSeen[$battle['id']] = true;
                $new[] = ['battle' => (int) $battle['id'],
                          'week'   => (int) $battle['week'],
                          'home'   => $battle['home'],
                          'away'   => $battle['away']];
            }
        }
        return $new === [] ? [] : ['battles' => $new];
    }

    private function changedFacts(): array
    {
        $tz = league_tz($this->leagueId);
        $shift = $this->shift();
        $instant = fn (string $wallTime): int
            => (new DateTimeImmutable($wallTime, $tz))->getTimestamp() - $shift;
        $midnight = fn (string $setting): int
            => $instant(setting($setting, '', $this->leagueId) . ' 00:00:00');
        $openings = db()->prepare("SELECT id, settles_at, status,
                                          poll_cycle_id IS NOT NULL AS priced
                                     FROM market_openings WHERE league_id = ?
                                 ORDER BY settles_at");
        $openings->execute([$this->leagueId]);
        $scheduled = [];
        foreach ($openings->fetchAll() as $opening) {
            $settled = isset($this->settledOpenings[$opening['id']]);
            if ($opening['status'] === 'open' || !$settled) {
                $scheduled[] = ['at' => $instant($opening['settles_at']),
                                'priced' => (bool) $opening['priced']];
            }
            if ($opening['status'] !== 'open') {
                $this->settledOpenings[$opening['id']] = true;
            }
        }
        $facts = [
            'openings'   => $scheduled,
            'boundaries' => [
                'narrows_at' => $midnight('buyback_narrows_on'),
                'closes_at'  => $midnight('buyback_closes_on'),
            ],
        ];
        $changed = array_filter($facts, fn (array $fact, string $name): bool
            => ($this->lastFacts[$name] ?? null) !== $fact, ARRAY_FILTER_USE_BOTH);
        $this->lastFacts = $facts;
        return $changed;
    }

    private function newPolls(): array
    {
        $st = db()->prepare('SELECT id, week, poll FROM poll_cycles
                              WHERE league_id = ? AND id > ? ORDER BY id');
        $st->execute([$this->leagueId, $this->pollMark]);
        $polls = $st->fetchAll();
        foreach ($polls as $poll) {
            $this->pollMark = max($this->pollMark, (int) $poll['id']);
        }
        return array_map(fn (array $poll): array
            => ['week' => (int) $poll['week'], 'poll' => $poll['poll']], $polls);
    }

    private function newLedgerRows(): array
    {
        $owner = db()->prepare(
            "SELECT l.id, 'owner' AS book, o.display_name AS owner,
                    l.transaction_type AS type, l.amount_cents AS amount,
                    l.balance_after_cents AS balance_after,
                    l.related_entity_type AS related_type,
                    l.related_entity_id AS related_id,
                    l.reversal_of_ledger_entry_id AS reversal_of
               FROM owner_funds_ledger l JOIN owners o ON o.id = l.owner_id
              WHERE l.league_id = ? AND l.id > ? ORDER BY l.id");
        $owner->execute([$this->leagueId, $this->ownerMark]);
        $house = db()->prepare(
            "SELECT l.id, 'house' AS book, o.display_name AS owner, l.source AS type,
                    l.amount_cents AS amount, l.balance_after_cents AS balance_after,
                    l.related_entity_type AS related_type,
                    l.related_entity_id AS related_id,
                    l.reversal_of_ledger_entry_id AS reversal_of
               FROM house_ledger l LEFT JOIN owners o ON o.id = l.owner_id
              WHERE l.league_id = ? AND l.id > ? ORDER BY l.id");
        $house->execute([$this->leagueId, $this->houseMark]);
        $rows = [...$owner->fetchAll(), ...$house->fetchAll()];
        foreach ($rows as $row) {
            if ($row['book'] === 'owner') {
                $this->ownerMark = max($this->ownerMark, (int) $row['id']);
            } else {
                $this->houseMark = max($this->houseMark, (int) $row['id']);
            }
        }
        return $rows;
    }
}

function league_setup(int $leagueId): array
{
    $settings = db()->prepare('SELECT skey, svalue FROM settings WHERE league_id = ?');
    $settings->execute([$leagueId]);
    $owners = db()->prepare('SELECT id, user_id, display_name, available_funds_cents
                               FROM owners WHERE league_id = ? ORDER BY id');
    $owners->execute([$leagueId]);
    return [
        'settings' => array_column($settings->fetchAll(), 'svalue', 'skey'),
        'owners'   => array_map(fn (array $owner): array => [
            'owner' => $owner['display_name'],
            'funds' => (int) $owner['available_funds_cents'],
        ], $owners->fetchAll()),
    ];
}

function owner_named_by_user(int $leagueId, int $userId): string
{
    $st = db()->prepare('SELECT display_name FROM owners
                          WHERE league_id = ? AND user_id = ?');
    $st->execute([$leagueId, $userId]);
    return (string) $st->fetchColumn();
}

function week_end(int $leagueId): array
{
    $owners = db()->prepare('SELECT display_name, available_funds_cents FROM owners
                              WHERE league_id = ? ORDER BY id');
    $owners->execute([$leagueId]);
    $teams = db()->prepare('SELECT t.name, o.display_name AS owner, t.acquired_price_cents
                              FROM teams t JOIN owners o ON o.id = t.owner_id
                             WHERE t.league_id = ? ORDER BY t.name');
    $teams->execute([$leagueId]);
    return [
        'funds' => array_column($owners->fetchAll(), 'available_funds_cents',
                                'display_name'),
        'teams' => array_map(fn (array $team): array => [
            'team' => $team['name'], 'owner' => $team['owner'],
            'basis' => (int) $team['acquired_price_cents'],
        ], $teams->fetchAll()),
        'house' => house_balance($leagueId),
    ];
}

const NUMBERED = [
    'trade'        => 'trades',
    'battle'       => 'battles',
    'transaction'  => 'transactions',
    'order'        => 'market_orders',
    'contribution' => 'contributions',
    'owner_ledger' => 'owner_funds_ledger',
    'house_ledger' => 'house_ledger',
];

final class Ids
{
    private array $names = [];
    private array $ordinals = [];

    public function __construct(int $leagueId, array $seen)
    {
        $this->names['team'] = $this->column(
            'SELECT id, name FROM teams WHERE league_id = ?', $leagueId);
        $this->names['owner'] = $this->column(
            'SELECT id, display_name FROM owners WHERE league_id = ?', $leagueId);
        $this->names['user'] = $this->column(
            'SELECT user_id, display_name FROM owners WHERE league_id = ?', $leagueId);
        foreach (NUMBERED as $kind => $table) {
            $ids = db()->prepare("SELECT id FROM {$table} WHERE league_id = ?");
            $ids->execute([$leagueId]);
            $everSeen = array_keys(($seen[$kind] ?? []) + array_fill_keys(
                array_map('intval', $ids->fetchAll(PDO::FETCH_COLUMN)), true));
            sort($everSeen);
            $this->ordinals[$kind] = array_flip($everSeen);
        }
    }

    private function column(string $sql, int $leagueId): array
    {
        $st = db()->prepare($sql);
        $st->execute([$leagueId]);
        return array_column($st->fetchAll(PDO::FETCH_NUM), 1, 0);
    }

    public function of(string $kind, mixed $id): mixed
    {
        if ($id === null || (int) $id === 0) {
            return null;
        }
        return $this->names[$kind][(int) $id] ?? (isset($this->ordinals[$kind][(int) $id])
            ? $this->ordinals[$kind][(int) $id] + 1 : "unknown {$kind} {$id}");
    }

    public function event(array $event): array
    {
        if (isset($event['in'])) {
            $event['in'] = $this->input($event['in']);
        }
        if (isset($event['ledger'])) {
            $event['ledger'] = array_map([$this, 'ledgerRow'], $event['ledger']);
        }
        if (isset($event['battles'])) {
            $event['battles'] = array_map(fn (array $battle): array
                => ['battle' => $this->of('battle', $battle['battle'])] + $battle,
                $event['battles']);
        }
        return $event;
    }

    private function input(array $in): array
    {
        $kinds = ['team_id' => 'team', 'team_out_id' => 'team', 'team_in_id' => 'team',
                  'to_owner_id' => 'owner', 'tx_id' => 'trade', 'battle_id' => 'battle',
                  'order_id' => 'order'];
        foreach ($in as $key => $value) {
            if (isset($kinds[$key])) {
                $in[$key] = $this->of($kinds[$key], $value);
            } elseif ($key === 'owner_ids') {
                $in[$key] = array_map(fn ($id) => $this->of('owner', $id), $value);
            }
        }
        return $in;
    }

    private function ledgerRow(array $row): array
    {
        $book = $row['book'] === 'owner' ? 'owner_ledger' : 'house_ledger';
        return [
            'book'          => $row['book'],
            'entry'         => $this->of($book, $row['id']),
            'owner'         => $row['owner'],
            'type'          => $row['type'],
            'amount'        => (int) $row['amount'],
            'balance_after' => (int) $row['balance_after'],
            'related'       => $row['related_type'] === null ? null : [
                $row['related_type'], $this->of($row['related_type'], $row['related_id']),
            ],
            'reversal_of'   => $this->of($book, $row['reversal_of']),
        ];
    }
}

function owners_act(int $leagueId, array $owners, callable $rng, callable $call,
                     callable $policy): void
{
    for ($i = count($owners) - 1; $i > 0; $i--) {
        $j = $rng($i + 1);
        [$owners[$i], $owners[$j]] = [$owners[$j], $owners[$i]];
    }
    foreach ($owners as $owner) {
        $_SESSION['user_id'] = (int) $owner['user_id'];
        $_SESSION['league_id'] = $leagueId;
        flush_caches();
        $membership = active_membership();
        if (!$membership) {
            continue;
        }
        foreach ($policy(dashboard_data($membership), $rng) as $intent) {
            $call('owner', $intent['action'], $intent['in'], (int) $owner['user_id'],
                  $leagueId);
            flush_caches();
        }
    }
}

function season_acting_twice(array $opts): array
{
    $seed = (int) $opts['seed'];
    $year = (int) $opts['year'];
    $rng = sim_rng($seed);
    $fixture = season_fixture_load($year);
    $people = array_merge(FACTORY_PEOPLE, [['dana', 'Dana'], ['marcus', 'Marcus'],
                                           ['priya', 'Priya'], ['wes', 'Wes']]);
    $floor = (int) round(0.85 * minimum_buy_in_cents(
        count($people), (int) PP_LEAGUE_SETTINGS['max_teams']['default'],
        (int) PP_LEAGUE_SETTINGS['battle_stake_cents']['default']));
    $league = factory_league([
        'name'   => "Recorded {$year} · seed {$seed} · acting twice a week",
        'people' => $people,
        'season' => $year,
        'teams'  => 0,
        'fund'   => $floor + $rng((int) round($floor * 1.35)),
    ]);
    $leagueId = $league['league_id'];
    season_fixture_teams($leagueId, $fixture);
    $calendar = replay_calendar($fixture);
    $delta = replay_delta($calendar, 1, 'open');
    replay_write_games($fixture, $calendar, $year, $delta);
    replay_set_boundaries($leagueId, $calendar, $delta);
    replay_apply_poll($leagueId, $fixture, $calendar, 1, $delta);
    sim_draft($leagueId, $league['owners'], $rng, $opts['call']);
    $lastWeek = min((int) $opts['weeks'], (int) ($fixture['last_week'] ?? 14));
    for ($week = 1; $week <= $lastWeek; $week++) {
        foreach (['open', 'aftermath'] as $moment) {
            $delta = replay_enter_week($leagueId, $fixture, $calendar, $year, $delta,
                                       $week, $moment);
            owners_act($leagueId, $league['owners'], $rng, $opts['call'],
                       $opts['policy']);
        }
        ($opts['check'])($week, $leagueId);
    }
    return [];
}

$trace = new Trace(season_fixture_load($year));
$pdo = db();
$pdo->beginTransaction();
try {
    ($twice ? 'season_acting_twice' : 'sim_run')([
        'seed'  => $seed,
        'year'  => $year,
        'weeks' => $weeks,
        'call'  => function (string $file, string $action, array $in, int $userId,
                             int $leagueId) use ($trace): array {
            $trace->begin($leagueId);
            $trace->settle('clock');
            $at = $trace->fixtureNow();
            $response = sim_call_action($file, $action, $in, $userId, $leagueId);
            $trace->settle('action', [
                'owner'  => owner_named_by_user($leagueId, $userId),
                'action' => $action,
                'in'     => $in,
                'status' => $response['status'],
                'error'  => $response['payload']['error'] ?? null,
            ], $at);
            return $response;
        },
        'policy' => function (array $view, callable $rng) use ($trace): array {
            $trace->settle('dashboard', ['owner' => owner_named_by_user(
                (int) $_SESSION['league_id'], (int) $_SESSION['user_id'])]);
            return sim_policy_random($view, $rng);
        },
        'check' => function (int $week, int $leagueId) use ($trace): void {
            $trace->settle('week_end', ['week' => $week] + week_end($leagueId));
            $bad = check_ledger_invariants($leagueId);
            if ($bad) {
                throw new RuntimeException("week {$week}: " . implode(' | ', $bad));
            }
        },
    ]);
    $trace->settle('end', week_end($trace->leagueId) + [
        'draft' => (string) db()->query('SELECT status FROM drafts WHERE league_id = '
                                        . $trace->leagueId . ' ORDER BY id DESC LIMIT 1')
                                ->fetchColumn(),
    ]);
    $ids = new Ids($trace->leagueId, $trace->seen);
    $trace->events = array_map([$ids, 'event'], $trace->events);
} finally {
    $pdo->rollBack();
}

function ties_against_the_schedule(array $events, array $fixture): array
{
    $place = [];
    foreach ($fixture['games'] as $week => $games) {
        foreach ($games as $index => $game) {
            $place["{$week}:{$game['home']}:{$game['away']}"] = [$game['kickoff'], $index];
        }
    }
    $against = [];
    foreach ($events as $event) {
        $battles = $event['battles'] ?? [];
        for ($i = 1; $i < count($battles); $i++) {
            [$earlier, $later] = [$battles[$i - 1], $battles[$i]];
            [$earlierKickoff, $earlierIndex]
                = $place["{$earlier['week']}:{$earlier['home']}:{$earlier['away']}"];
            [$laterKickoff, $laterIndex]
                = $place["{$later['week']}:{$later['home']}:{$later['away']}"];
            if ($earlierKickoff === $laterKickoff && $earlierIndex > $laterIndex) {
                $against[] = "week {$earlier['week']}: {$earlier['home']} before "
                           . "{$later['home']}";
            }
        }
    }
    return $against;
}

$against = ties_against_the_schedule($trace->events, season_fixture_load($year));
if ($against) {
    fwrite(STDERR, "Battles on games kicking off together were created out of schedule "
        . "order, which MariaDB does now and then (ORDER BY kickoff_at has no tie-break). "
        . "Nothing written; record again.\n  " . implode("\n  ", $against) . "\n");
    exit(1);
}

$file = __DIR__ . "/{$year}-seed-{$seed}" . ($weeks === 0 ? '-draft' : '')
       . ($twice ? '-twice' : '') . '.json';
$flags = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR;
$events = $trace->events;
$commit = trim((string) shell_exec('git -C ' . escapeshellarg($pp26dev)
                                   . ' rev-parse HEAD'));
file_put_contents($file, json_encode(['pp26dev' => $commit, 'year' => $year,
                                      'seed' => $seed], $flags) . "\n"
    . implode("\n", array_map(fn (array $event): string => json_encode($event, $flags),
                              $events)) . "\n");
$answers = array_count_values(array_map(fn (array $event): string
    => $event['status'] < 400 ? 'accepted' : 'refused',
    array_filter($events, fn (array $event): bool => $event['event'] === 'action')));
printf("%s: %d events, %d accepted, %d refused\n", basename($file), count($events),
       $answers['accepted'] ?? 0, $answers['refused'] ?? 0);
