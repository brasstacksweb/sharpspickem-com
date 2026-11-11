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
                    l.reversal_of_ledger_entry_id AS reversal_of,
                    l.description
               FROM owner_funds_ledger l JOIN owners o ON o.id = l.owner_id
              WHERE l.league_id = ? AND l.id > ? ORDER BY l.id");
        $owner->execute([$this->leagueId, $this->ownerMark]);
        $house = db()->prepare(
            "SELECT l.id, 'house' AS book, o.display_name AS owner, l.source AS type,
                    l.amount_cents AS amount, l.balance_after_cents AS balance_after,
                    l.related_entity_type AS related_type,
                    l.related_entity_id AS related_id,
                    l.reversal_of_ledger_entry_id AS reversal_of,
                    NULL AS description
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
        'prize_pool' => prize_pool($leagueId),
    ];
}

function prize_pool(int $leagueId): ?int
{
    $st = db()->prepare("SELECT svalue FROM settings
                          WHERE league_id = ? AND skey = 'prize_pool_cents'");
    $st->execute([$leagueId]);
    $pool = $st->fetchColumn();
    return $pool === false ? null : (int) $pool;
}

const NUMBERED = [
    'trade'        => 'trades',
    'battle'       => 'battles',
    'transaction'  => 'transactions',
    'order'        => 'market_orders',
    'contribution' => 'contributions',
    'owner_ledger' => 'owner_funds_ledger',
    'house_ledger' => 'house_ledger',
    'payout'       => 'payouts',
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
                  'order_id' => 'order', 'contribution_id' => 'contribution',
                  'owner_id' => 'owner'];
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
        ] + ($row['type'] === 'commissioner_adjustment'
             ? ['reason' => $row['description']] : []);
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

function dollars(int $cents): string
{
    return sprintf('%s%d.%02d', $cents < 0 ? '-' : '', intdiv(abs($cents), 100),
                   abs($cents) % 100);
}

function pending_contribution(int $ownerId): ?int
{
    $st = db()->prepare('SELECT id FROM contributions WHERE owner_id = ? AND status = "pending"');
    $st->execute([$ownerId]);
    return ($id = $st->fetchColumn()) === false ? null : (int) $id;
}

function owner_of(int $leagueId, int $userId): array
{
    $st = db()->prepare('SELECT id, available_funds_cents AS funds FROM owners
                          WHERE league_id = ? AND user_id = ?');
    $st->execute([$leagueId, $userId]);
    return $st->fetch();
}

function corrections(int $leagueId, Trace $trace, callable $call, callable $rng): void
{
    $users = array_map('intval', array_column(db()->query(
        "SELECT user_id FROM owners WHERE league_id = {$leagueId} ORDER BY id")->fetchAll(),
        'user_id'));
    $commissioner = array_shift($users);
    catch_up_league($leagueId);
    flush_caches();
    $trace->settle('dashboard', ['owner' => owner_named_by_user($leagueId, $commissioner)]);
    for ($i = count($users) - 1; $i > 0; $i--) {
        $j = $rng($i + 1);
        [$users[$i], $users[$j]] = [$users[$j], $users[$i]];
    }
    [$mistaken, $withdrawn, $rejected] = $users;
    $act = function (int $userId, string $file, string $action, array $in = [])
        use ($call, $leagueId): void {
        $call($file, $action, $in, $userId, $leagueId);
        flush_caches();
    };
    $topUp = 1000 + 100 * $rng(40);
    $act($mistaken, 'owner', 'request_additional_funds', ['amount' => dollars($topUp)]);
    $act($mistaken, 'owner', 'request_additional_funds', ['amount' => dollars($topUp)]);
    $typo = pending_contribution(owner_of($leagueId, $mistaken)['id']);
    $act($commissioner, 'commissioner', 'confirm_contribution',
         ['contribution_id' => $typo, 'amount' => dollars(10 * $topUp)]);
    $act($commissioner, 'commissioner', 'reverse_contribution', ['contribution_id' => $typo]);
    $act($commissioner, 'commissioner', 'reverse_contribution', ['contribution_id' => $typo]);
    $act($mistaken, 'owner', 'request_additional_funds', ['amount' => dollars($topUp)]);
    $act($commissioner, 'commissioner', 'confirm_contribution',
         ['contribution_id' => pending_contribution(owner_of($leagueId, $mistaken)['id'])]);
    $act($withdrawn, 'owner', 'request_additional_funds', ['amount' => dollars($topUp)]);
    $act($withdrawn, 'owner', 'cancel_fund_request',
         ['contribution_id' => pending_contribution(owner_of($leagueId, $withdrawn)['id'])]);
    $act($rejected, 'owner', 'request_additional_funds', ['amount' => dollars($topUp)]);
    $act($commissioner, 'commissioner', 'reject_contribution',
         ['contribution_id' => pending_contribution(owner_of($leagueId, $rejected)['id'])]);
    $adjusted = owner_of($leagueId, $withdrawn)['id'];
    $correction = (500 + 100 * $rng(25)) * ($rng(2) === 0 ? -1 : 1);
    $act($commissioner, 'commissioner', 'adjust_available_funds',
         ['owner_id' => $adjusted, 'amount' => dollars($correction),
          'reason' => ' Corrected a recording error ']);
    $act($commissioner, 'commissioner', 'adjust_available_funds',
         ['owner_id' => $adjusted, 'amount' => '0.00', 'reason' => 'Nothing at all']);
    $act($commissioner, 'commissioner', 'adjust_available_funds',
         ['owner_id' => $adjusted, 'amount' => dollars($correction), 'reason' => '  ']);
    $act($rejected, 'commissioner', 'adjust_available_funds',
         ['owner_id' => owner_of($leagueId, $rejected)['id'], 'amount' => '5.00',
          'reason' => 'Paying myself']);
}

function left_open(int $leagueId, Trace $trace, callable $act): void
{
    $bidder = db()->query("SELECT id, user_id FROM owners WHERE league_id = {$leagueId}
                            ORDER BY available_funds_cents DESC, id LIMIT 1")->fetch();
    $_SESSION['user_id'] = (int) $bidder['user_id'];
    $_SESSION['league_id'] = $leagueId;
    flush_caches();
    $view = dashboard_data(active_membership());
    $trace->settle('dashboard', ['owner' => owner_named_by_user($leagueId,
                                                                (int) $bidder['user_id'])]);
    $ranked = array_values(array_filter($view['teams'], fn ($team) => $team['owner_id'] === null
        && (int) $team['market_value_cents'] > 0));
    usort($ranked, fn ($one, $other) => [(int) $one['market_value_cents'], (int) $one['id']]
        <=> [(int) $other['market_value_cents'], (int) $other['id']]);
    if ($ranked) {
        $act((int) $bidder['user_id'], 'owner', 'submit_bid',
             ['team_id' => (int) $ranked[0]['id'],
              'amount' => dollars((int) $ranked[0]['market_value_cents'])]);
    }
    $unpromised = "SELECT t.id, o.id AS owner_id, o.user_id FROM teams t
                     JOIN owners o ON o.id = t.owner_id
                    WHERE t.league_id = {$leagueId}
                      AND NOT EXISTS (SELECT 1 FROM trades r
                                       WHERE r.status = 'pending'
                                         AND t.id IN (r.team_a_id, r.team_b_id))";
    $offered = db()->query("{$unpromised} ORDER BY t.id LIMIT 1")->fetch();
    if (!$offered) {
        return;
    }
    $wanted = db()->query("{$unpromised} AND o.id <> {$offered['owner_id']}
                           ORDER BY t.id LIMIT 1")->fetch();
    if (!$wanted) {
        return;
    }
    $act((int) $offered['user_id'], 'owner', 'propose_trade',
         ['to_owner_id' => (int) $wanted['owner_id'], 'team_out_id' => (int) $offered['id'],
          'team_in_id' => (int) $wanted['id'], 'cash' => '0.00', 'cash_direction' => 'they_pay',
          'note' => 'Left open']);
}

function after_the_close(int $leagueId, callable $act): void
{
    $trade = db()->query("SELECT r.id, a.user_id AS proposer, b.user_id AS partner
                            FROM trades r JOIN owners a ON a.id = r.owner_a_id
                            JOIN owners b ON b.id = r.owner_b_id
                           WHERE r.league_id = {$leagueId} AND r.note = 'Left open'
                        ORDER BY r.id DESC LIMIT 1")->fetch();
    if ($trade) {
        $act((int) $trade['partner'], 'owner', 'confirm_trade', ['tx_id' => (int) $trade['id']]);
        $act((int) $trade['proposer'], 'owner', 'cancel_trade', ['tx_id' => (int) $trade['id']]);
    }
    $order = db()->query("SELECT m.id, o.user_id FROM market_orders m
                            JOIN owners o ON o.id = m.owner_id
                           WHERE m.league_id = {$leagueId} AND m.kind = 'bid'
                        ORDER BY m.id DESC LIMIT 1")->fetch();
    if ($order) {
        $act((int) $order['user_id'], 'owner', 'reorder_bid',
             ['order_id' => (int) $order['id'], 'direction' => 'up']);
        $act((int) $order['user_id'], 'owner', 'cancel_order', ['order_id' => (int) $order['id']]);
    }
}

function postseason(int $leagueId, int $year, int $seed, Trace $trace, array $opts): void
{
    $fixture = season_fixture_load($year);
    $calendar = replay_calendar($fixture);
    $delta = replay_delta_observed($fixture, $year);
    $owners = db()->prepare('SELECT user_id FROM owners WHERE league_id = ? ORDER BY id');
    $owners->execute([$leagueId]);
    $owners = $owners->fetchAll();
    $rng = sim_rng($seed * 7919 + $year);
    $commissioner = (int) $owners[0]['user_id'];
    $waiting = (int) $owners[count($owners) - 1]['user_id'];
    $act = function (int $userId, string $file, string $action, array $in = [])
        use ($opts, $leagueId): void {
        ($opts['call'])($file, $action, $in, $userId, $leagueId);
        flush_caches();
    };
    $closing = array_key_last($calendar['rounds']);
    if ($closing === null) {
        left_open($leagueId, $trace, $act);
    }
    foreach ([...array_keys($calendar['rounds']), 'done'] as $round) {
        $delta = replay_enter_week($leagueId, $fixture, $calendar, $year, $delta, $round,
                                   'open');
        lock_house($leagueId);
        sync_payouts_for_league($leagueId, $year);
        flush_caches();
        $trace->settle('payouts', ['round' => $round]);
        if ($round !== 'done') {
            owners_act($leagueId, $owners, $rng, $opts['call'], $opts['policy']);
        }
        if ($round === $closing) {
            left_open($leagueId, $trace, $act);
        }
        if ($round === array_key_first($calendar['rounds'])) {
            $act($waiting, 'owner', 'request_additional_funds', ['amount' => '25.00']);
        }
        if ($round === 'done') {
            after_the_close($leagueId, $act);
            $act($commissioner, 'commissioner', 'confirm_contribution',
                 ['contribution_id' => pending_contribution(owner_of($leagueId, $waiting)['id'])]);
            $lowest = db()->query("SELECT id, available_funds_cents AS funds FROM owners
                                    WHERE league_id = {$leagueId}
                                    ORDER BY available_funds_cents, id LIMIT 1")->fetch();
            $act($commissioner, 'commissioner', 'adjust_available_funds',
                 ['owner_id' => (int) $lowest['id'],
                  'amount' => dollars(-((int) $lowest['funds'] + 500 + 100 * $rng(25))),
                  'reason' => 'Owes the league for a side bet']);
        }
        $settles = $round === 'done' ? 2 : 1;
        for ($attempt = 0; $attempt < $settles; $attempt++) {
            $act($commissioner, 'commissioner', 'settle_season');
        }
        if ($round === 'done') {
            $last = (int) db()->query("SELECT MAX(id) FROM contributions
                                        WHERE league_id = {$leagueId}")->fetchColumn();
            $act($commissioner, 'commissioner', 'reverse_contribution',
                 ['contribution_id' => $last]);
            $act($commissioner, 'commissioner', 'adjust_available_funds',
                 ['owner_id' => owner_of($leagueId, $waiting)['id'], 'amount' => '5.00',
                  'reason' => 'Too late']);
            $act($waiting, 'owner', 'request_additional_funds', ['amount' => '25.00']);
        }
        ($opts['check'])($round, $leagueId);
    }
}

$trace = new Trace(season_fixture_load($year));
$correctionsRng = sim_rng($seed * 104729 + $year);
$correctionsWeek = 4 + $correctionsRng(5);
$callAction = null;
$pdo = db();
$pdo->beginTransaction();
try {
    $opts = [
        'seed'  => $seed,
        'year'  => $year,
        'weeks' => $weeks,
        'call'  => $callAction = function (string $file, string $action, array $in,
                                           int $userId, int $leagueId) use ($trace): array {
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
        'check' => function (int|string $week, int $leagueId)
            use ($trace, &$callAction, $correctionsRng, $correctionsWeek): void {
            if ($week === $correctionsWeek) {
                corrections($leagueId, $trace, $callAction, $correctionsRng);
            }
            catch_up_league($leagueId);
            flush_caches();
            $trace->settle('week_end', ['week' => $week] + week_end($leagueId));
            $bad = check_ledger_invariants($leagueId);
            if ($bad) {
                throw new RuntimeException("week {$week}: " . implode(' | ', $bad));
            }
        },
    ];
    ($twice ? 'season_acting_twice' : 'sim_run')($opts);
    if ($weeks >= 99) {
        postseason($trace->leagueId, $year, $seed, $trace, $opts);
    }
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

function ties_against_the_owners(array $events): array
{
    $place = array_flip(array_column($events[0]['owners'], 'owner'));
    $against = [];
    foreach ($events as $event) {
        if (($event['action'] ?? null) !== 'settle_season' || $event['status'] >= 400) {
            continue;
        }
        $rows = $event['ledger'];
        for ($i = 1; $i < count($rows); $i++) {
            [$earlier, $later] = [$rows[$i - 1], $rows[$i]];
            if ($earlier['amount'] === $later['amount']
                && $place[$earlier['owner']] > $place[$later['owner']]) {
                $against[] = "season settlement: {$earlier['owner']} before "
                           . "{$later['owner']}";
            }
        }
    }
    return $against;
}

$against = [...ties_against_the_schedule($trace->events, season_fixture_load($year)),
            ...ties_against_the_owners($trace->events)];
if ($against) {
    fwrite(STDERR, "Rows that tie on what MariaDB orders them by (a kickoff, or a balance "
        . "at the season settlement) came back out of the order the port takes, which "
        . "MariaDB does now and then. Nothing written; record again.\n  "
        . implode("\n  ", $against) . "\n");
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
