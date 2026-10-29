-- Sharps Pick 'Em — MySQL schema (multi-league, integer-cents economy)
-- Imports into an already-created database (no CREATE DATABASE here, so it
-- works on shared hosting where the DB is provisioned in the control panel).
-- Run: mysql -u pp26dev_user -p pp26dev_db < setup/schema.sql
--
-- MONEY: every monetary value is an integer number of cents (INT). Format to
-- "$X.XX" only at the view edge. There is NO real money here — Available Funds
-- and the House Account are virtual records; the Commissioner settles real money
-- off-platform (see money.pdf / the Official Rulebook).

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS league_join_requests;
DROP TABLE IF EXISTS league_requests;
DROP TABLE IF EXISTS auth_tokens;
DROP TABLE IF EXISTS invites;
DROP TABLE IF EXISTS login_attempts;
DROP TABLE IF EXISTS settings;
DROP TABLE IF EXISTS payouts;
DROP TABLE IF EXISTS house_ledger;
DROP TABLE IF EXISTS owner_funds_ledger;
DROP TABLE IF EXISTS contributions;
DROP TABLE IF EXISTS battles;
DROP TABLE IF EXISTS drop_orders;
DROP TABLE IF EXISTS bids;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS team_ratings;
DROP TABLE IF EXISTS trades;
DROP TABLE IF EXISTS rankings;
DROP TABLE IF EXISTS teams;
DROP TABLE IF EXISTS league_economy_settings;
DROP TABLE IF EXISTS owners;
DROP TABLE IF EXISTS leagues;
DROP TABLE IF EXISTS users;
SET FOREIGN_KEY_CHECKS = 1;

-- Login identity. One human = one row, may belong to several leagues.
-- is_superadmin gates league provisioning (approving league requests, creating leagues).
--
-- EMAIL IS THE ACCOUNT. There is no second identifier to forget, and every route back
-- in — invite, password reset — already goes to this address, so an account whose email
-- is wrong is an account nobody can recover. NOT NULL is what makes that true.
-- WHICH MIGRATIONS THIS DATABASE HAS ALREADY HAD.
--
-- setup/schema.sql stays the complete description of the CURRENT schema, so a fresh install
-- is one file and needs no replay of history. Migrations exist for the databases that
-- already hold data — and the two only agree because `bin/db.php reset` records every
-- migration as applied after loading this file. Without that a fresh install would try to
-- apply changes it was already built with.
CREATE TABLE schema_migrations (
  filename VARCHAR(200) NOT NULL PRIMARY KEY,
  applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  -- Chosen by the person at signup and editable by them. Seeds owners.display_name on
  -- every membership, where a per-league override lives; changing it here deliberately
  -- does NOT rewrite those. Width matches owners.display_name so seeding cannot truncate.
  display_name VARCHAR(100) NOT NULL,
  email_verified_at DATETIME NULL,
  is_superadmin TINYINT(1) NOT NULL DEFAULT 0,
  password_hash VARCHAR(255) NOT NULL,
  -- WHAT ENDS EVERY OTHER SESSION. A sign-in lasts PP_SESSION_DAYS of inactivity, so
  -- changing a password is not enough on its own: the session an attacker already holds
  -- outlives the reset by up to ninety days, which is exactly backwards for the one action
  -- a person takes BECAUSE they think they are compromised. login stores this value in the
  -- session and current_user() compares it on every request — free, because that function
  -- already reads this row — so bumping it here logs every device out at once.
  -- An INT rather than a timestamp: it is compared, never displayed, and a counter cannot
  -- be caught out by a clock (see the THREE CLOCKS rule in CLAUDE.md).
  session_epoch INT NOT NULL DEFAULT 0,
  -- CLOSED, NOT DELETED, because deleted is not available: owners.id carries restricting
  -- foreign keys (counted on owners.status) and owners.user_id cascades into them, so DELETE FROM users fails outright
  -- for anyone who has ever played (error 1451). Any user who has ever SENT an invite is
  -- doubly blocked, since invites.invited_by_user_id is NOT NULL with no referential action.
  -- So closing scrubs the row in place: the email becomes a non-routable placeholder, the
  -- name a neutral constant, the hash a value nobody knows, and session_epoch moves.
  -- owners.display_name is deliberately NOT scrubbed — it is what keeps the Official Record
  -- of the league's games readable, and that history belongs to the league too.
  closed_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- A league is an isolated game world with its own owners, teams, and treasury.
CREATE TABLE leagues (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  season INT NOT NULL,
  created_by_user_id INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Owner = a user's membership in one league. is_commissioner is per-league.
-- available_funds_cents is the owner's virtual in-game spending balance; it is
-- the running total of the owner_funds_ledger and is never real money.
CREATE TABLE owners (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  league_id INT NOT NULL,
  display_name VARCHAR(100) NOT NULL,
  is_commissioner TINYINT(1) NOT NULL DEFAULT 0,
  available_funds_cents INT NOT NULL DEFAULT 0,
  -- 'inactive' is a REMOVED member, written by deactivate_membership(). Removal has to be
  -- soft: this table's id carries 20 restricting foreign keys (of 24 pointing here), so a
  -- DELETE fails for anyone who has ever played. That count is stated HERE and nowhere else —
  -- it was written in five places and all five said 21 after the schema had moved on. Every owner query filters on 'active' — and any check for "is this
  -- person already in this league" must too, or a removed member can never be invited back,
  -- which §13 explicitly allows since removal is pre-draft and so is the invitation.
  status ENUM('active','inactive') NOT NULL DEFAULT 'active',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_user_league (user_id, league_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- Teams. owner_id NULL = owned by the House.
-- acquired_price_cents / acquired_at record what the CURRENT OWNER paid; set on any
-- transfer to an owner, nulled on return to the House. It is that owner's own profit
-- and loss — the portfolio's unrealized figure and `transactions.basis_cents`.
CREATE TABLE teams (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  name VARCHAR(100) NOT NULL,
  conference VARCHAR(40) NOT NULL DEFAULT '',
  conference_type ENUM('P4','G5','IND') NOT NULL DEFAULT 'P4',
  owner_id INT NULL,
  acquired_price_cents INT NULL,
  acquired_at DATETIME NULL,
  UNIQUE KEY uq_league_team (league_id, name),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  -- NOT `ON DELETE SET NULL`, and the CHECK below is why. MySQL refuses a CHECK on a
  -- column a referential action writes (error 3823) — correctly, because SET NULL would
  -- clear owner_id and leave acquired_price_cents behind, which is precisely the state
  -- property 7 forbids. The action is unreachable anyway: nothing an owner or a
  -- Commissioner can do deletes an owner or a league. The two routes that DO delete one
  -- are development-only and both suspend referential integrity for their span rather
  -- than relying on an action here — `bin/db.php reset` and devtime_reset(), which drop
  -- with FOREIGN_KEY_CHECKS=0. If owner deletion is ever wanted in the app, it must clear
  -- the basis itself rather than have the FK silently strand it.
  FOREIGN KEY (owner_id) REFERENCES owners(id),
  -- Ledger property 7, made structural: an owned team always carries a cost basis and an
  -- unowned one never does. A disposal copies that basis onto the transaction row, so a
  -- mismatch records the wrong realized gain. Safe as a row-level CHECK because every
  -- path that moves a team writes owner_id and the basis in the SAME statement — see the
  -- `apply_*` helpers in bootstrap.php. Split them across two UPDATEs and this fires,
  -- which is the point.
  CONSTRAINT ck_team_basis CHECK (
    (owner_id IS NULL) = (acquired_price_cents IS NULL)
  )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- One row per poll this league has applied. THE unit of market time: prices come from a
-- cycle, the market opens because a cycle arrived, and the league week IS the cycle.
--
-- It exists because (league_id, week) could not identify a poll. The AP Top 25 and the
-- Playoff Committee rankings both carry a week number, and from week 11 they BOTH publish
-- for the same week — AP on the Sunday, the committee on the Tuesday. The old
-- `uq_league_week_team` let the second overwrite the first row for row, and `ON DUPLICATE
-- KEY UPDATE` does not touch `created_at`, so the new poll silently inherited the old
-- one's arrival time. That arrival time is the ONLY temporal signal a poll carries —
-- CFBD publishes no poll timestamps at all — so a market that opens when a poll lands
-- would never have opened for the committee's first poll, which is also §8's transition.
--
-- `uq_cycle` is what makes the hourly sync idempotent, and it is also the app's only
-- "a new poll arrived" event: INSERT IGNORE, and a rowCount of 0 means this is a re-run.
--
-- applied_at is MySQL's clock (a `created_at`, so compare it SQL-side).
CREATE TABLE poll_cycles (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  week INT NOT NULL,
  poll ENUM('AP','CFP') NOT NULL,
  applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_cycle (league_id, week, poll),
  KEY idx_latest (league_id, id),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- A full snapshot of every team's rank at one poll cycle. FULL: a team that is unranked
-- gets a row carrying NULL, so a team dropping out of the Top 25 falls to unranked
-- rather than keeping the last rank anyone wrote for it.
--
-- week/poll are denormalised from the cycle for display and are written in the same
-- statement, so they cannot drift. NEVER filter on them — `WHERE week = 11` matches both
-- the AP and the committee poll for that week. Price from a CYCLE (rankings_at_cycle).
CREATE TABLE rankings (
  id INT AUTO_INCREMENT PRIMARY KEY,
  cycle_id INT NOT NULL,
  league_id INT NOT NULL,
  week INT NOT NULL,
  poll ENUM('AP','CFP') NOT NULL,
  team_id INT NOT NULL,
  rank_pos INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_cycle_team (cycle_id, team_id),
  KEY idx_league (league_id),
  FOREIGN KEY (cycle_id) REFERENCES poll_cycles(id) ON DELETE CASCADE,
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Computer ratings for the whole FBS, and the composite drawn from them.
--
-- SEASON-SCOPED, NOT LEAGUE-SCOPED, for the same reason `games` is not: there is one real
-- FBS and every league reads it.
--
-- WHAT IT IS FOR, and what it must never touch. Past #25 every team reads "Unranked", and
-- alphabetically that tells an owner nothing about which programs are closest to breaking
-- in — which matters because unranked teams are free to add (§5). This orders them.
-- It is INFORMATIONAL ONLY: Market Value comes from the official poll and nothing else
-- (§3), and nothing here is read by market_value_cents(), the sale path, the bid path or
-- the playoff payouts. `TheCompositeTest` fails if that ever stops being true.
--
-- The four input ranks are stored beside the answer on purpose. A composite nobody can
-- decompose is a number owners will not trust, and it is the only way to tell "SP+ hates
-- them" from "the feed dropped a system this week".
--
-- NOT the Massey Composite, which Spencer asked for and which has no API — it is a scrape
-- of a site we do not control. These four are CFBD's own, from the client we already have.
CREATE TABLE team_ratings (
  id INT AUTO_INCREMENT PRIMARY KEY,
  season INT NOT NULL,
  team_name VARCHAR(120) NOT NULL,          -- CFBD's spelling; joined to teams.name
  sp_rank INT NULL,                         -- SP+        (/ratings/sp,  has `ranking`)
  srs_rank INT NULL,                        -- SRS        (/ratings/srs, has `ranking`)
  fpi_rank INT NULL,                        -- FPI        (/ratings/fpi, derived from the value)
  elo_rank INT NULL,                        -- Elo        (/ratings/elo, derived from the value)
  systems TINYINT NOT NULL DEFAULT 0,       -- how many fed the mean; a team short one still ranks
  composite_rank INT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_rating (season, team_name),
  KEY idx_season_rank (season, composite_rank)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ONE OWNER-TO-OWNER TRADE (§9) — the offer while it is being negotiated, and the header
-- of the exchange once it settles.
--
-- §9 caps a trade at ONE TEAM IN EACH DIRECTION plus cash, which is every shape its own
-- examples use: "Alabama for $20" (team_a, cash to a), "Michigan for Notre Dame" (both
-- teams, no cash), "Oregon and $5 for Penn State", "Georgia for Clemson and $8". Nothing
-- bundles two teams travelling together, so there is no legs table — two nullable columns
-- say it exactly, and the CHECKs below are then single-row and single-table, which is the
-- only kind of invariant a constraint can hold (see ck_team_basis).
--
-- `cash_cents` IS SIGNED and read from A's side: positive means B pays A, negative means A
-- pays B. One column rather than an amount plus a direction, because two columns can
-- disagree and this one cannot.
--
-- IT SETTLES WHOLLY OR NOT AT ALL. Both teams change hands and the cash moves in the same
-- transaction; if any team is unavailable (§6) the entire trade is HELD — not half-applied
-- and not cancelled — and the next market opening tries the whole thing again.
CREATE TABLE trades (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  owner_a_id INT NOT NULL,                 -- the proposing side
  owner_b_id INT NOT NULL,                 -- the counterparty
  team_a_id INT NULL,                      -- team A sends to B (NULL: A sends no team)
  team_b_id INT NULL,                      -- team B sends to A (NULL: B sends no team)
  cash_cents INT NOT NULL DEFAULT 0,       -- SIGNED: >0 B pays A, <0 A pays B
  note VARCHAR(500) NOT NULL DEFAULT '',
  status ENUM('pending','approved','rejected') NOT NULL DEFAULT 'pending',
  counterparty_confirmed TINYINT(1) NOT NULL DEFAULT 0,
  submitted_by INT NOT NULL,               -- owner id; §9 needs no third party
  decided_by INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  decided_at DATETIME NULL,
  -- ONE PENDING TRADE PER TEAM, as a UNIQUE key rather than a check-then-INSERT: two taps
  -- on a slow connection are two proposals, and propose_trade's team_committed_to_trade()
  -- check runs before the INSERT, so both pass. A team promised twice can be delivered
  -- once, and the loser is held for ever.
  --
  -- Generated from `status` ALONE, with league_id in the index instead of the expression,
  -- because MySQL refuses a stored generated column whose base column carries an
  -- ON DELETE CASCADE foreign key (error 1215) — and league_id does. Same shape as
  -- uq_one_open_draft and uq_one_pending_join_request.
  --
  -- TWO KEYS, because a team can sit on either side, and the NULLs are why this works:
  -- a UNIQUE key skips rows where any part is NULL, so a cash-only side constrains
  -- nothing. They do not cover a team appearing as team_a in one trade and team_b in
  -- another — only its own owner can offer it, but which SIDE that is depends on who
  -- proposed — so propose_trade also locks the team rows and re-checks. The keys are the
  -- structural backstop for the common case; the lock is the complete answer.
  pending_marker TINYINT GENERATED ALWAYS AS (CASE WHEN status = 'pending' THEN 1 END) STORED,
  UNIQUE KEY uq_pending_trade_team_a (league_id, team_a_id, pending_marker),
  UNIQUE KEY uq_pending_trade_team_b (league_id, team_b_id, pending_marker),
  KEY idx_league_status (league_id, status),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_a_id) REFERENCES owners(id),
  FOREIGN KEY (owner_b_id) REFERENCES owners(id),
  FOREIGN KEY (team_a_id) REFERENCES teams(id),
  FOREIGN KEY (team_b_id) REFERENCES teams(id),
  FOREIGN KEY (submitted_by) REFERENCES owners(id),
  CONSTRAINT ck_trade_two_sides CHECK (owner_a_id <> owner_b_id),
  -- A trade moves a team. Without one there is nothing to record and nothing to price.
  CONSTRAINT ck_trade_moves_a_team CHECK (team_a_id IS NOT NULL OR team_b_id IS NOT NULL),
  -- CASH ONLY MOVES AGAINST A TEAM COMING THE OTHER WAY, and this is arithmetic before it
  -- is policy. check_ledger_consistency()'s property 9 requires, per owner,
  --     Σ(amount on the legs they give up) − Σ(basis booked on what they receive)
  --       = the net cash they receive
  -- so an owner who is paid but gives up no team has no leg to carry the amount, and one
  -- who pays but receives no team has nothing to book the payment onto. Either way the
  -- standings stop adding up, and every figure still looks reasonable on its own.
  CONSTRAINT ck_trade_cash_backed CHECK (
    (cash_cents <= 0 OR team_a_id IS NOT NULL) AND (cash_cents >= 0 OR team_b_id IS NOT NULL)
  )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Ownership/money events. One `kind` per way a team changes hands, each named for the
-- section that grants it — and named the SAME here, in owner_funds_ledger and in
-- house_ledger, because one event writes to all three:
--   draft           House -> owner, at Market Value on draft night      (§5)
--   add             House -> owner, $0, unranked only                   (§5)
--   house_purchase  House -> owner, a winning blind bid OR an outright
--                   purchase at Market Value — one money path, and the
--                   `note` says which mechanism                          (§7)
--   drop            owner -> House, $0                                  (§6)
--   house_sale      owner -> House at Market Value                      (§8)
--   trade           owner -> owner, terms the two owners set            (§9)
--
-- KEEP THIS LIST HONEST — describe what each value IS, never what it is for. A comment
-- reading "purchase: House -> owner" beside a `purchase` written only by the free add is
-- how the Official Record came to label every §5 give-away "Purchase" against $0.00, with
-- the comment documenting an intent the code never implemented and nothing able to notice.
--
-- EVERY ROW HERE IS A THING THAT HAPPENED. A trade under negotiation lives in `trades`
-- and only reaches this table when it settles — one row per team that actually moved, so
-- a team-for-team swap writes two, one per disposal. A trade is NOT proposed here as a
-- `pending` row: that conflates an offer with a record, and a swap is two disposals by two
-- different owners, which one row (one `from_owner_id`, one `basis_cents`) cannot carry
-- however it is stretched.
CREATE TABLE transactions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  kind ENUM('draft','add','house_purchase','drop','house_sale','trade') NOT NULL,
  team_id INT NOT NULL,
  from_owner_id INT NULL,
  to_owner_id INT NULL,
  amount_cents INT NOT NULL DEFAULT 0,        -- price paid by receiving party
  house_amount_cents INT NOT NULL DEFAULT 0,  -- portion entering(+)/leaving(-) the House Account
  -- What the team had cost the owner who is giving it up, captured at the moment they
  -- do. teams.acquired_price_cents is cleared or overwritten by the same operation, so
  -- this is the only surviving record of the basis a realized gain is measured against.
  -- NULL where no owner gives anything up (a draft pick, an auction win).
  basis_cents INT NULL,
  -- The trade this row is one leg of (§9), NULL for every other kind. A swap's two rows
  -- share it, which is what lets a view show the exchange rather than half of it.
  trade_id INT NULL,
  note VARCHAR(500) NOT NULL DEFAULT '',
  status ENUM('pending','approved','rejected') NOT NULL DEFAULT 'pending',
  submitted_by INT NOT NULL,
  decided_by INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  decided_at DATETIME NULL,
  KEY idx_trade (trade_id),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (team_id) REFERENCES teams(id),
  FOREIGN KEY (from_owner_id) REFERENCES owners(id),
  FOREIGN KEY (to_owner_id) REFERENCES owners(id),
  FOREIGN KEY (submitted_by) REFERENCES owners(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ONE MARKET OPENING, as a thing that can be processed exactly once.
--
-- `settles_at` is the moment the market opens — which is the same moment the backlog
-- queued since the last opening is cleared, in one pass, in §6's order. It is scheduled
-- by a POLL ARRIVING, not by a weekday: sync_rankings_for_league() writes one when a new
-- poll_cycles row lands, at the next occurrence of the league's `market_open_time`.
--
-- Keyed to the moment rather than to the cycle, so two polls landing before the same
-- morning collapse into ONE opening — which is right, since owners get one re-priced
-- market either way. `uq_opening` is what makes the write idempotent, so two concurrent
-- requests cannot schedule the same opening twice.
--
-- LEAGUE-LOCAL wall time: written through league_tz(), so read it the same way, and
-- decide "has it arrived?" in PHP and NEVER as `settles_at <= NOW()` in SQL — see
-- due_openings().
CREATE TABLE market_openings (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  settles_at DATETIME NOT NULL,
  status ENUM('open','processed') NOT NULL DEFAULT 'open',
  processed_at DATETIME NULL,
  -- THE POLL THIS OPENING PRICES, and NULL when it prices nothing.
  --
  -- Normally a poll schedules the opening (sync_rankings_for_league) and this names it.
  -- But current_opening() also mints one whenever none is scheduled, so an owner always has
  -- somewhere to queue — and those carry no poll, because no poll has landed. The
  -- distinction is load-bearing rather than descriptive: §6 holds a played team off the
  -- House board until its result is PRICED, and last_opening_at() answered that with the
  -- most recent opening of any kind. So a fallback opening settling the morning after a
  -- game cleared the guard without repricing anything, and the whole board went buyable at
  -- last week's values with the results already public — the Florida State case §6 exists
  -- to prevent, arriving by another door. Only an opening carrying a cycle prices anything.
  poll_cycle_id INT NULL,
  UNIQUE KEY uq_opening (league_id, settles_at),
  KEY idx_open (league_id, status, settles_at),
  KEY idx_priced (league_id, status, poll_cycle_id, processed_at),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (poll_cycle_id) REFERENCES poll_cycles(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Every market action an owner takes: bids, free adds, drops, sales.
--
-- Two kinds of row live here since §6 split live from queued. An action on an AVAILABLE
-- team happens on the spot and is written `outcome='done'` as a record of what was already
-- applied. An action on an unavailable one is written `pending` against the next opening,
-- and process_opening() settles the whole backlog in one transaction, in §6's order.
-- Replaces the old `bids` and `drop_orders` tables.
--
-- uq_open_order is load-bearing rather than hygiene: it stops an owner queueing two
-- orders for the same team (a drop AND a sale, say), which is what keeps the resolution
-- order free of special cases. An owner cannot create a conflict with themselves, so no
-- step has to arbitrate one.
--
-- It applies to OPEN orders only, via a STORED marker that is 1 while `outcome='pending'`
-- and NULL otherwise — MySQL has no partial index, and a UNIQUE key skips NULLs. That
-- matters now that an order on an available team executes immediately and is written
-- `done`: an owner can legitimately buy a team, sell it, and buy it back inside one poll
-- cycle, and a key spanning settled rows would refuse the second act. The marker is
-- generated from `outcome` alone, which carries no referential action — a generated
-- column over an ON DELETE CASCADE base column is rejected outright (error 1215).
CREATE TABLE market_orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  opening_id INT NOT NULL,
  league_id INT NOT NULL,
  owner_id INT NOT NULL,
  kind ENUM('bid','add','drop','sale') NOT NULL,
  team_id INT NOT NULL,
  amount_cents INT NULL,                     -- bids only
  drop_if_acquired TINYINT(1) NOT NULL DEFAULT 0,  -- conditional drop: consumed only if a slot is needed
  -- §7/Q23: the OWNER's ranking of their own bids, ascending — lower is kept first when
  -- they win more teams than they can hold. Bids only; §5 settles contested free adds by
  -- who asked first. A new bid takes max+1 for that owner and opening, so it appends, and
  -- 0 across the board means no preference at all (ties fall to bid id).
  priority INT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),  -- ms precision: the bid tie-break reads it
  outcome ENUM('pending','done','void') NOT NULL DEFAULT 'pending',
  outcome_note VARCHAR(300) NOT NULL DEFAULT '',   -- why a bid lost or a add failed; owners see this
  open_marker TINYINT GENERATED ALWAYS AS (IF(outcome = 'pending', 1, NULL)) STORED,
  UNIQUE KEY uq_open_order (league_id, owner_id, team_id, open_marker),
  KEY idx_opening_kind (opening_id, kind),
  FOREIGN KEY (opening_id) REFERENCES market_openings(id) ON DELETE CASCADE,
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id),
  FOREIGN KEY (team_id) REFERENCES teams(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



-- Battles: optional wagers between two owners. Stakes/winnings use Available Funds.
-- The week's schedule, cached from CFBD so nothing in a user's request path has to
-- make a network call. Not scoped to a league: the schedule is the same for everyone,
-- and each league matches its own teams against it by name (the roster sync uses CFBD
-- names, so they line up).
--
-- `spread` is refreshed on every sync until kickoff and frozen after — §11 settles a
-- Battle on the line "at kickoff", and the last line we saw before the game started is
-- that number. `kickoff_at` is what makes both the freeze and the no-Battle-after-
-- kickoff rule possible.
CREATE TABLE games (
  id INT AUTO_INCREMENT PRIMARY KEY,
  season INT NOT NULL,
  week INT NOT NULL,
  season_type VARCHAR(12) NOT NULL DEFAULT 'regular',
  home_team VARCHAR(120) NOT NULL,
  away_team VARCHAR(120) NOT NULL,
  kickoff_at DATETIME NULL,                  -- NULL until CFBD schedules it
  kickoff_tbd TINYINT(1) NOT NULL DEFAULT 0,  -- the date is set and the time is not; kickoff_at's time is a placeholder
  spread DECIMAL(5,1) NULL,                  -- quoted from the HOME side; negative = home favored
  spread_provider VARCHAR(40) NULL,
  spread_updated_at DATETIME NULL,
  completed TINYINT(1) NOT NULL DEFAULT 0,
  home_points INT NULL,
  away_points INT NULL,
  notes VARCHAR(200) NOT NULL DEFAULT '',   -- CFBD's own label; how a CFP round is identified
  -- CFBD's own game id — the join for /scoreboard. NOT unique: uniq_game keys on the week,
  -- so a postponed game arrives as a second row carrying the same id.
  cfbd_id INT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uniq_game (season, week, season_type, home_team, away_team),
  KEY idx_cfbd_game (cfbd_id),
  KEY idx_week (season, week, season_type),
  KEY idx_kickoff (kickoff_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE battles (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  week INT NULL,
  owner_a_id INT NOT NULL,
  owner_b_id INT NOT NULL,
  team_a_id INT NULL,
  team_b_id INT NULL,
  terms VARCHAR(500) NOT NULL,
  stake_cents INT NOT NULL,
  pending_stake_cents INT NULL,                   -- a raise one owner offered (§11), unanswered
  pending_stake_by_owner_id INT NULL,             -- who offered it; the other owner answers
  house_pct DECIMAL(5,2) NOT NULL DEFAULT 0.00,   -- used only when battle rule = 'house'
  spread_source VARCHAR(80) NULL,
  -- §11 (Q36): TWO MEANINGS, and which one applies depends on `status`. While the Battle is
  -- `accepted` this is the line as it stood when the Battle was CREATED, which §11 calls
  -- provisional — the wager is not fixed until 30 minutes before kickoff. At settlement it is
  -- overwritten with the line that actually decided it (games.spread, which sync_schedule
  -- stops updating at the freeze), so a settled row records the number the money moved on.
  -- Never settle from this column while the Battle is open; read the game.
  spread DECIMAL(5,1) NULL,
  favorite_owner_id INT NULL,
  -- `pending` is a matchup that EXISTS but has not bound (§11, Q39): no stake taken, neither
  -- team off the board. It becomes `accepted` 30 minutes before kickoff, when the line
  -- freezes and whoever still holds the two teams is committed. Everything that means "live"
  -- filters status='accepted' — availability_map(), both escrow readers, ledger property 11,
  -- battles_with_scores() — so a pending row is inert by construction rather than by care.
  --
  -- `rejected` is the failed bind: at the freeze one of the two could not cover the stake.
  -- It is terminal, and keeping the row is what makes that final — uq_battle_matchup is
  -- status-agnostic, so the row itself is what prevents a second attempt. A matchup that
  -- DISSOLVES instead (a team was dropped, sold or traded before the freeze) is deleted
  -- rather than rejected, so the same two teams can pair up again if the team comes back.
  --
  -- DEFAULT stays 'accepted': every direct INSERT outside sync_battles_for_league() — the
  -- factory's, and the tests' — means a live Battle and should not have to say so.
  status ENUM('pending','accepted','settled','rejected','refunded') NOT NULL DEFAULT 'accepted',
  winner_owner_id INT NULL,
  settlement_note VARCHAR(300) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  settled_at DATETIME NULL,
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_a_id) REFERENCES owners(id),
  FOREIGN KEY (owner_b_id) REFERENCES owners(id),
  FOREIGN KEY (team_a_id) REFERENCES teams(id),
  FOREIGN KEY (team_b_id) REFERENCES teams(id),
  -- These three name an owner as plainly as owner_a_id does; they were simply never
  -- declared. `winner_owner_id` is the one that matters — it decides who was paid.
  FOREIGN KEY (winner_owner_id) REFERENCES owners(id),
  FOREIGN KEY (favorite_owner_id) REFERENCES owners(id),
  FOREIGN KEY (pending_stake_by_owner_id) REFERENCES owners(id),
  -- Ledger property 8, made structural: a settled Battle names a winner. Without one the
  -- reserved stakes were never released and the money is stranded in a row nobody reads
  -- again. `refunded` (a push) is deliberately NOT covered — it has no winner by rule.
  CONSTRAINT ck_battle_settled_has_winner CHECK (status <> 'settled' OR winner_owner_id IS NOT NULL),
  -- "The open Battles in this league" is asked on every page load that renders a battle
  -- view, because settlement runs on read as well as from cron. The league_id FK index
  -- alone makes that a scan of every Battle the league has ever had.
  KEY idx_battle_open (league_id, status),
  -- One Battle per matchup per week (§11), as a UNIQUE key rather than the check-then-
  -- INSERT that sync_battles_for_league() performs against an in-PHP map. That map is
  -- only safe while callers are serialized, and creation now also runs on a page load —
  -- two at once would create the Battle twice and debit all four stakes. The week is part
  -- of the key because two teams can legitimately meet twice in a season (a regular-season
  -- game and then the conference championship), and those are two separate Battles. Home
  -- and away roles come from the fixture, so the reversed pair cannot occur. NULL team ids
  -- (fixture rows) skip a UNIQUE key, which is the behaviour wanted.
  UNIQUE KEY uq_battle_matchup (league_id, week, team_a_id, team_b_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Off-platform Contributions: money an owner sends the Commissioner directly.
-- Available Funds change ONLY when the Commissioner confirms receipt.
CREATE TABLE contributions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  owner_id INT NOT NULL,
  contribution_type ENUM('initial','additional','manual','refund') NOT NULL,
  requested_amount_cents INT NOT NULL DEFAULT 0,
  confirmed_amount_cents INT NULL,
  status ENUM('pending','confirmed','rejected','cancelled','reversed') NOT NULL DEFAULT 'pending',
  requested_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  confirmed_at DATETIME NULL,
  confirmed_by_user_id INT NULL,
  note VARCHAR(500) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  -- One open funds request per owner (see the check-then-INSERT in actions/owner.php).
  pending_marker TINYINT GENERATED ALWAYS AS (CASE WHEN status = 'pending' THEN 1 END) STORED,
  UNIQUE KEY uq_one_pending_contribution (owner_id, pending_marker),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id),
  FOREIGN KEY (confirmed_by_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Owner Available Funds ledger. amount_cents is signed (+credit / -debit).
-- balance_after_cents is the owner's running balance after this entry.
CREATE TABLE owner_funds_ledger (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  owner_id INT NOT NULL,
  -- The set is the union of PP_LEDGER_EXTERNAL['owner'] and PP_LEDGER_INTERNAL['owner'];
  -- ConventionsTest asserts this ENUM and those two constants stay identical. An ENUM
  -- rather than a VARCHAR with the values in a comment, because that comment drifts — and
  -- a typo'd type is then caught only by the next ledger audit, instead of by the INSERT.
  transaction_type ENUM(
    'contribution','commissioner_adjustment','reversal','season_settlement',
    'draft_purchase','draft_reversal','house_purchase',
    'house_sale',
    'trade_payment','trade_receipt',
    'battle_stake','battle_winnings','battle_refund','payout'
  ) NOT NULL,
  amount_cents INT NOT NULL,
  balance_after_cents INT NOT NULL,
  description VARCHAR(300) NOT NULL DEFAULT '',
  related_entity_type VARCHAR(30) NULL,    -- team, trade, battle, bid, contribution, payout
  related_entity_id INT NULL,
  authorized_by_user_id INT NULL,
  reversal_of_ledger_entry_id INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id),
  FOREIGN KEY (authorized_by_user_id) REFERENCES users(id) ON DELETE SET NULL,
  FOREIGN KEY (reversal_of_ledger_entry_id) REFERENCES owner_funds_ledger(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- House Account ledger. amount_cents signed (+in / -out). balance_after_cents is
-- the running League treasury balance. Balance = SUM(amount_cents) for the league.
CREATE TABLE house_ledger (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  amount_cents INT NOT NULL,
  source ENUM('draft','house_purchase','battle','house_sale',
              'payout','reversal') NOT NULL,
  description VARCHAR(300) NOT NULL DEFAULT '',
  balance_after_cents INT NOT NULL DEFAULT 0,
  owner_id INT NULL,
  related_entity_type VARCHAR(30) NULL,
  related_entity_id INT NULL,
  authorized_by_user_id INT NULL,
  reversal_of_ledger_entry_id INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id) ON DELETE SET NULL,
  FOREIGN KEY (authorized_by_user_id) REFERENCES users(id) ON DELETE SET NULL,
  FOREIGN KEY (reversal_of_ledger_entry_id) REFERENCES house_ledger(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Playoff payouts (a % of the Playoff Prize Pool per win), paid off-platform.
-- One row per owner per week: what their position was worth at that poll.
--
-- Derived data, deliberately STORED. Everything else about a portfolio is computed on
-- demand precisely so it cannot drift — but history is the one thing that cannot be
-- recomputed, because money and ownership events carry no week. This is the same call
-- the app already makes for payouts.prize_pool_amount_cents, battles.spread and
-- transactions.basis_cents: record the number at the moment it is knowable, or lose it.
--
-- house_cents repeats across every owner row for a week. That is denormalised on
-- purpose: it makes "the league at week 8" one query, one code path writes it, and the
-- alternative is a second table holding a single integer.
CREATE TABLE portfolio_snapshots (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  owner_id INT NOT NULL,
  week INT NOT NULL,
  team_value_cents INT NOT NULL DEFAULT 0,
  cash_cents INT NOT NULL DEFAULT 0,
  portfolio_value_cents INT NOT NULL DEFAULT 0,
  unrealized_cents INT NOT NULL DEFAULT 0,
  realized_cents INT NOT NULL DEFAULT 0,
  battle_net_cents INT NOT NULL DEFAULT 0,
  contributed_cents INT NOT NULL DEFAULT 0,
  house_cents INT NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_owner_week (league_id, owner_id, week),
  KEY idx_league_week (league_id, week),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE payouts (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  owner_id INT NULL,                         -- NULL when the winning team had no owner (§12, forfeited share)
  team_id INT NOT NULL,
  playoff_round ENUM('bye','first_round','quarterfinal','semifinal','championship') NOT NULL,
  payout_percentage DECIMAL(5,2) NOT NULL,
  prize_pool_amount_cents INT NOT NULL DEFAULT 0,
  projected_amount_cents INT NOT NULL DEFAULT 0,
  approved_amount_cents INT NULL,
  -- 'forfeited' = the winning team was House-owned, so this slot pays nothing and its
  -- share rolls into the rounds still to be paid (§12, Q14).
  status ENUM('projected','approved','paid','forfeited') NOT NULL DEFAULT 'projected',
  paid_at DATETIME NULL,
  marked_paid_by_user_id INT NULL,
  note VARCHAR(300) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  -- ONE SLOT PAYS ONCE. §12's fifteen slots each pay a percentage of the frozen pool, so a
  -- second row for the same slot pays the House out twice and the fifteen no longer sum to
  -- the whole. Two routes record them — `cron_sync_payouts` and the Commissioner's fallback
  -- form — and the form's duplicate check runs BEFORE it takes lock_house(), so a
  -- double-submit, or the form racing the hourly cron, gets past it. A key sees both.
  UNIQUE KEY uq_payout_slot (league_id, team_id, playoff_round),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (team_id) REFERENCES teams(id),
  FOREIGN KEY (owner_id) REFERENCES owners(id),
  FOREIGN KEY (marked_paid_by_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Per-league key/value game settings.
CREATE TABLE settings (
  league_id INT NOT NULL,
  skey VARCHAR(50) NOT NULL,
  -- TEXT, not VARCHAR(200): payment_instructions is a free-text setting whose own
  -- shipped default is 196 characters, so the old width 500'd on the first edit.
  -- PP_SETTING_TYPES declares the real per-type limit.
  svalue TEXT NOT NULL,
  PRIMARY KEY (league_id, skey),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Preseason snake draft. One non-complete draft per league at a time. The turn
-- pointer is (current_round, current_position) into the round's snake order;
-- `version` bumps on every mutation so the draft page can poll for changes.
-- Ownership + money still flow through teams/transactions/ledgers (draft_picks is
-- draft-specific metadata: round, overall pick number, price, and the txn it made).
CREATE TABLE drafts (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  season INT NOT NULL,
  status ENUM('setup','active','complete') NOT NULL DEFAULT 'setup',
  current_round INT NOT NULL DEFAULT 1,
  current_position INT NOT NULL DEFAULT 1,
  passed_since_pick VARCHAR(255) NOT NULL DEFAULT '',   -- CSV of owner ids who passed since the last pick
  version INT NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  started_at DATETIME NULL,
  completed_at DATETIME NULL,
  -- "At most one unfinished draft per league" must not live only in a check-then-INSERT in
  -- actions/draft.php, which is a TOCTOU gap. MySQL has no partial index, but this gives
  -- one: the marker is 1 while the draft is open and NULL once it completes, and a UNIQUE
  -- key ignores rows where any part is NULL. So any number of `complete` drafts coexist
  -- while a second open one cannot be written. Same trick in `contributions` and
  -- `league_requests`.
  --
  -- The marker is generated from `status` ALONE, with the scope column in the index rather
  -- than in the expression, because MySQL refuses a stored generated column whose base
  -- column carries an ON DELETE CASCADE foreign key (error 1215) — and league_id does.
  open_marker TINYINT GENERATED ALWAYS AS (CASE WHEN status IN ('setup','active') THEN 1 END) STORED,
  UNIQUE KEY uq_one_open_draft (league_id, open_marker),
  KEY idx_drafts_league (league_id, status),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The draft order: position 1..N in round 1 (snake reverses it each even round).
CREATE TABLE draft_order (
  draft_id INT NOT NULL,
  position INT NOT NULL,
  owner_id INT NOT NULL,
  PRIMARY KEY (draft_id, position),
  UNIQUE KEY uq_draft_owner (draft_id, owner_id),
  FOREIGN KEY (draft_id) REFERENCES drafts(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- One row per actual selection (passes are not recorded here — they only bump the
-- draft's pointer + consecutive_passes). transaction_id links the money record.
CREATE TABLE draft_picks (
  id INT AUTO_INCREMENT PRIMARY KEY,
  draft_id INT NOT NULL,
  overall_pick INT NOT NULL,
  round INT NOT NULL,
  owner_id INT NOT NULL,
  team_id INT NOT NULL,
  price_cents INT NOT NULL DEFAULT 0,
  transaction_id INT NULL,
  -- Undoing a pick REVERSES it, never erases it: the money side already posts a
  -- reversal entry rather than deleting a ledger row, and the board history has to
  -- tell the same story. Readers filter on `undone_at IS NULL`.
  undone_at DATETIME NULL,
  undone_by_user_id INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- ONE LIVE PICK PER SLOT, enforced rather than checked. The lock in lock_draft() is
  -- what prevents two picks racing onto one slot; this is what NOTICES if that lock is
  -- ever removed, in the shape CLAUDE.md prescribes for "only one of these at a time".
  --
  -- Generated rather than a plain UNIQUE on (draft_id, overall_pick), because an undone
  -- pick KEEPS its row — the money side posts a reversal instead of deleting a ledger
  -- entry, and the board history has to tell the same story — while overall_pick is
  -- MAX(...)+1 over `undone_at IS NULL`, so a re-pick legitimately reuses the number. The
  -- marker is NULL once undone and a UNIQUE key skips NULLs, so only live picks collide.
  -- Derived from undone_at/overall_pick alone: a generated column built on draft_id would
  -- be rejected outright (error 1215), since that column carries ON DELETE CASCADE.
  live_pick INT GENERATED ALWAYS AS (CASE WHEN undone_at IS NULL THEN overall_pick END) STORED,
  UNIQUE KEY uq_draft_pick_slot (draft_id, live_pick),
  FOREIGN KEY (draft_id) REFERENCES drafts(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id),
  FOREIGN KEY (team_id) REFERENCES teams(id),
  -- Both single-table references that were simply never declared. The transaction is the
  -- money side of the pick; undoing one is what a reversal points back at.
  FOREIGN KEY (transaction_id) REFERENCES transactions(id),
  FOREIGN KEY (undone_by_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Owner comments on a battle ("Battle Board") or trade ("Trade Talk"). Soft-deleted
-- (deleted_at) to preserve the record, per the ledger philosophy. context_id points
-- at battles.id or transactions.id depending on context_type.
CREATE TABLE comments (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  context_type ENUM('battle','trade','draft') NOT NULL,
  context_id INT NOT NULL,
  owner_id INT NOT NULL,
  body VARCHAR(1000) NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  edited_at DATETIME NULL,
  deleted_at DATETIME NULL,
  -- WHO removed it, which is what the tombstone needs to say (Q27). A comment the author
  -- removed and one the Commissioner removed render differently, so "deleted" alone is not
  -- enough: moderation has to be visible AS moderation, or it is indistinguishable from
  -- someone thinking better of a post.
  deleted_by_owner_id INT NULL,
  KEY idx_comments_context (league_id, context_type, context_id, id),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id),
  FOREIGN KEY (deleted_by_owner_id) REFERENCES owners(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Failed sign-in attempts, for login throttling. Not league-scoped (keyed by IP).
CREATE TABLE login_attempts (
  id INT AUTO_INCREMENT PRIMARY KEY,
  ip VARCHAR(45) NOT NULL,
  -- The identifier that was tried — an email. WIDE ENOUGH FOR ONE: at VARCHAR(50) a long
  -- address makes this INSERT throw 1406 under strict mode, which api.php turns into a
  -- generic 500 on the FAILED-LOGIN path, so the person is told "something went wrong"
  -- instead of "wrong email or password" and the throttle stops counting them entirely.
  -- Without strict mode it truncates instead, which is the same bug without the noise.
  --
  -- Also carries the '__pwreset__' sentinel, which is how password-reset requests are
  -- throttled on this table: one throttle and one sweep, so a reset flood cannot hide
  -- behind a login flood. The sweep at the top of `login` bounds retention to a day,
  -- which matters now that these are real addresses rather than usernames.
  identifier VARCHAR(255) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_ip_time (ip, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Emailed invites. token_hash = SHA-256 of the raw token that travels in the email
-- link; single-use and expiring.
--
-- league_id NULL is a PLATFORM invite — a super-admin putting a person on the platform,
-- which creates an account and no membership. Set is a LEAGUE invite from a commissioner:
-- account plus membership. ONE table and ONE accept_invite, because both carry the same
-- promise: this address was proven by delivery, and the person holding it chooses their
-- own password. Two tables would be two token vocabularies for one guarantee.
--
-- `role` is meaningless on a platform invite and is simply left at its default there;
-- accept_invite only reads it inside the league branch.
CREATE TABLE invites (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NULL,
  email VARCHAR(255) NOT NULL,
  role ENUM('owner','commissioner') NOT NULL DEFAULT 'owner',
  token_hash CHAR(64) NOT NULL UNIQUE,
  invited_by_user_id INT NOT NULL,
  status ENUM('pending','accepted','revoked') NOT NULL DEFAULT 'pending',
  expires_at DATETIME NOT NULL,
  accepted_at DATETIME NULL,
  accepted_by_user_id INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_invite_league_email (league_id, email),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (invited_by_user_id) REFERENCES users(id),
  FOREIGN KEY (accepted_by_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Single-use auth tokens for password reset.
CREATE TABLE auth_tokens (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  type ENUM('password_reset') NOT NULL,
  token_hash CHAR(64) NOT NULL UNIQUE,
  expires_at DATETIME NOT NULL,
  used_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_authtoken_user (user_id, type),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Requests to create a new league; a super-admin approves or declines.
CREATE TABLE league_requests (
  id INT AUTO_INCREMENT PRIMARY KEY,
  requested_by_user_id INT NOT NULL,
  name VARCHAR(120) NOT NULL,
  season INT NOT NULL,
  note VARCHAR(500) NOT NULL DEFAULT '',
  status ENUM('pending','approved','declined') NOT NULL DEFAULT 'pending',
  decided_by_user_id INT NULL,
  decided_at DATETIME NULL,
  created_league_id INT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- One open league request per user (see the check-then-INSERT in actions/league.php).
  pending_marker TINYINT GENERATED ALWAYS AS (CASE WHEN status = 'pending' THEN 1 END) STORED,
  UNIQUE KEY uq_one_pending_league_request (requested_by_user_id, pending_marker),
  FOREIGN KEY (requested_by_user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (decided_by_user_id) REFERENCES users(id) ON DELETE SET NULL,
  FOREIGN KEY (created_league_id) REFERENCES leagues(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Somebody with no account asking for one, from the public landing page. The step BEFORE
-- league_requests above: there a user asks a super-admin for a league, here a stranger asks
-- for the account that would let them.
--
-- It exists because the email is not enough on its own. A promotion sends a burst of people
-- at an unpredictable moment, and a capture that only mails has lost the lead the first time
-- Postmark hiccups or a message lands in spam, with nothing to reconcile against. The row is
-- the durable half; the mail is a prompt.
--
-- No FK to users, and no email uniqueness beyond the open one: the whole point is that this
-- person has no account, and the same address may legitimately ask again after being
-- declined.
CREATE TABLE access_requests (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL,
  status ENUM('new','invited','declined') NOT NULL DEFAULT 'new',
  -- Where the request came from, so a second entry point is distinguishable later without
  -- a schema change. 'landing' is the only writer today.
  source VARCHAR(60) NOT NULL DEFAULT 'landing',
  decided_by_user_id INT NULL,
  decided_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- ONE OPEN REQUEST PER ADDRESS, as a key rather than a check-then-INSERT. It is also the
  -- mail cap: a resubmission collides here, so nothing is recorded and nothing is sent, and
  -- somebody refreshing the form cannot flood the inbox it notifies. Generated from `status`
  -- alone so the column has no dependency on a cascading parent.
  open_marker TINYINT GENERATED ALWAYS AS (CASE WHEN status = 'new' THEN 1 END) STORED,
  UNIQUE KEY uq_one_open_access_request (email, open_marker),
  KEY idx_access_status (status, created_at),
  FOREIGN KEY (decided_by_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- A signed-in user asking to join a DISCOVERABLE league they are not in; the
-- commissioner of that league decides. The mirror of league_requests one level down —
-- there a user asks a super-admin for a league, here for a seat in one.
--
-- Approval calls create_membership(), the same helper an accepted invite calls, so a
-- membership comes into existence exactly one way however it was asked for. Which is
-- also why there is no created_owner_id: the owners row IS the record that this was
-- approved, and a pointer to it would be a second copy with nothing keeping them agreed.
CREATE TABLE league_join_requests (
  id INT AUTO_INCREMENT PRIMARY KEY,
  league_id INT NOT NULL,
  user_id INT NOT NULL,
  note VARCHAR(500) NOT NULL DEFAULT '',
  status ENUM('pending','approved','declined') NOT NULL DEFAULT 'pending',
  decided_by_user_id INT NULL,
  decided_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  -- One open request per user per league, as a UNIQUE key rather than a check-then-INSERT:
  -- two taps on a slow connection are two requests, and only the key sees both. Generated
  -- from the STATUS column alone — a generated column over a base column carrying
  -- ON DELETE CASCADE is rejected (error 1215), and both FKs below cascade.
  pending_marker TINYINT GENERATED ALWAYS AS (CASE WHEN status = 'pending' THEN 1 END) STORED,
  UNIQUE KEY uq_one_pending_join_request (league_id, user_id, pending_marker),
  KEY idx_join_req_league_status (league_id, status, id),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (decided_by_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Cron job heartbeat. One row per scheduled run, whether it succeeded or not.
--
-- The point is the ABSENCE of rows, not their contents. A job that throws is the easy
-- case — it can email. The failure that actually costs money is a job that never runs
-- at all: cron never installed, wrong PHP binary, .env missing in production, an
-- expired CFBD key, a rebuilt server. None of those raise anything, so nothing can
-- report them; only a missing heartbeat can. job_health() reads this and the Site
-- Console renders it, because cron is a platform concern rather than a league one.
CREATE TABLE job_runs (
  id INT AUTO_INCREMENT PRIMARY KEY,
  job VARCHAR(40) NOT NULL,                  -- key in PP_JOBS
  started_at DATETIME NOT NULL,
  finished_at DATETIME NULL,                 -- NULL = still running, or died hard
  ok TINYINT(1) NOT NULL DEFAULT 0,          -- ran to completion without throwing
  summary VARCHAR(500) NOT NULL DEFAULT '',  -- one line for the console
  error TEXT NULL,
  KEY idx_job_started (job, started_at),
  KEY idx_started (started_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Every CFBD request the app has made, and what came back.
--
-- Two problems, one table, and both are the same blindness. CFBD sells calls by the
-- CALENDAR MONTH and disables a key that runs out, so the failure arrives as a 429 on
-- every endpoint at once with weeks of syncing having given no warning at all — and the
-- jobs then keep asking, 288 times a day for the five-minute line job alone, none of which
-- can succeed before the month turns over.
--
-- So cfbd_get() records each call here and reads the same rows back before making the next
-- one: the newest `calls_remaining` is what /site publishes against CFBD_MONTHLY_QUOTA,
-- the per-endpoint counts say where it went, and the most recent 429 is what holds the
-- next call off. Derived every way, which is the shape weeks_with_lines_about_to_freeze()
-- already uses — a stored "we are rate limited" flag would need its own writer and could
-- be left set long after the month rolled over.
CREATE TABLE cfbd_calls (
  id INT AUTO_INCREMENT PRIMARY KEY,
  called_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,  -- MySQL's clock, so compare SQL-side
  path VARCHAR(60) NOT NULL,                 -- the endpoint alone, never the query string
  http_code SMALLINT NOT NULL,               -- 0 when the transport failed before any response
  calls_remaining INT NULL,                  -- CFBD's own `x-calllimit-remaining`, when it sent one
  retry_after VARCHAR(40) NULL,              -- whatever a 429 carried; undocumented, so possibly never
  KEY idx_called (called_at),
  KEY idx_path_called (path, called_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The notification outbox. Nothing sends email inline; notify() writes a row here and
-- cron_send_notifications drains it.
--
-- Queuing is not an optimisation, it is what makes the layer correct. Every event worth
-- mailing about fires either inside with_transaction() (process_opening), inside an
-- owner's page load (the lazy settlement path in dashboard_data), or in a burst across
-- every league (a poll moving 25 teams). An inline HTTP call to Postmark is wrong in all
-- three: it would mail about money a rollback then un-moved, it would put ~300ms per
-- owner into a dashboard render, and the lazy path is required to swallow its failures,
-- which would silently swallow the notifications too. An INSERT joins the caller's
-- transaction, so a rolled-back opening takes its notifications with it.
--
-- `vars` is snapshotted AT QUEUE TIME. "Updated cash balance" in a battle-result email
-- means the balance after that Battle settled, not whenever the mailer got to the row.
-- That also makes this table the record of what an owner was actually told — which is
-- the thing the market opening has never had: a refused order moves no money, so its
-- outcome_note is the only account of it that exists anywhere.
CREATE TABLE notifications (
  id INT AUTO_INCREMENT PRIMARY KEY,
  handle VARCHAR(60) NOT NULL,               -- key in PP_NOTIFICATIONS
  league_id INT NULL,                        -- NULL for user-level mail (no league scope)
  owner_id INT NULL,                         -- NULL when addressed to a user, not a membership
  user_id INT NOT NULL,
  to_email VARCHAR(255) NOT NULL,            -- resolved at queue time; the address it was aimed at
  vars JSON NOT NULL,                        -- the merged variable set, as of the event
  -- "Tell them once, not every time we notice." NULL for the normal case — an event that
  -- has happened and should be reported every time it happens — and a caller-supplied
  -- identity for the notifications that describe a STATE rather than an event. A UNIQUE
  -- key skips NULLs, so this constrains only the rows that opt in.
  --
  -- battle_not_created is the one that needed it: a Battle nobody can fund writes no row,
  -- so the sync re-notices it on every scan. That was hourly from cron and became once per
  -- page load when creation started running on read.
  dedupe_key VARCHAR(120) NULL,
  status ENUM('queued','sent','failed') NOT NULL DEFAULT 'queued',
  attempts INT NOT NULL DEFAULT 0,
  error VARCHAR(500) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  sent_at DATETIME NULL,
  KEY idx_pending (status, id),
  KEY idx_owner (owner_id, created_at),
  UNIQUE KEY uq_notify_once (handle, owner_id, dedupe_key),
  FOREIGN KEY (league_id) REFERENCES leagues(id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id) REFERENCES owners(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Which groups of email an owner has switched OFF.
--
-- REFUSALS, not a full preference set. Storing the exceptions is what makes on the
-- default without seeding a row per owner per group, and what lets a group added later
-- be on for everyone with no backfill — the same reason `dedupe_key` above is NULL for
-- the normal case rather than carrying a value nobody reads.
--
-- Keyed on the OWNER, so a preference is per league: the same human in two leagues has
-- two memberships and may be loud in one and quiet in the other. That falls out of the
-- key rather than being arranged.
--
-- `ngroup` is a VARCHAR and not an ENUM on purpose. Its vocabulary is PP_NOTIFY_GROUPS,
-- which is itself derived from the notification manifest, so an ENUM would be a third
-- copy of a list that already exists twice. The action allowlists against the constant.
CREATE TABLE notification_optouts (
  owner_id INT NOT NULL,
  ngroup VARCHAR(30) NOT NULL,               -- key in PP_NOTIFY_GROUPS
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (owner_id, ngroup),
  FOREIGN KEY (owner_id) REFERENCES owners(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
