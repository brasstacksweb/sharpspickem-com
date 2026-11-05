<?php

declare(strict_types=1);

$pp26dev = getenv('PP26DEV') ?: getenv('HOME') . '/Projects/plassman-pickem';
require $pp26dev . '/setup/simulator.php';

$options = getopt('', ['year::', 'seed::', 'weeks::']);
$year = (int) ($options['year'] ?? 2024);
$seed = (int) ($options['seed'] ?? 1);
$weeks = (int) ($options['weeks'] ?? 99);

final class Trace
{
    public ?int $leagueId = null;
    public array $events = [];
    public array $seen = [];
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
        $this->events[] = ['event' => $event, 'at' => $at ?? $this->fixtureNow()] + $detail
            + ['polls' => $this->newPolls(), 'ledger' => $this->newLedgerRows()];
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
        $firstKickoff = (int) db()->query(
            'SELECT MIN(UNIX_TIMESTAMP(kickoff_at)) FROM games')->fetchColumn();
        return time() - ($firstKickoff - $this->firstKickoff);
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

$trace = new Trace(season_fixture_load($year));
$pdo = db();
$pdo->beginTransaction();
try {
    $result = sim_run([
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

$file = __DIR__ . "/{$year}-seed-{$seed}" . ($weeks === 0 ? '-draft' : '') . '.json';
$flags = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR;
$events = array_filter($trace->events, fn (array $event): bool
    => $event['event'] !== 'clock' || $event['ledger'] !== [] || $event['polls'] !== []);
$commit = trim((string) shell_exec('git -C ' . escapeshellarg($pp26dev)
                                   . ' rev-parse HEAD'));
file_put_contents($file, json_encode(['pp26dev' => $commit, 'year' => $year,
                                      'seed' => $seed], $flags) . "\n"
    . implode("\n", array_map(fn (array $event): string => json_encode($event, $flags),
                              $events)) . "\n");
printf("%s: %d events, %d accepted, %d refused\n", basename($file), count($events),
       $result['accepted'], $result['refused']);
