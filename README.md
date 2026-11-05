# Sharps Pick 'Em — Erlang

The Erlang/OTP port of Sharps Pick 'Em, a college football team-ownership game, and the
start of its multi-sport version.

**Status: not started.** This repository holds the plan and a frozen copy of the PHP app
to port from. Read [`AGENTS.md`](AGENTS.md) first: it is the conventions, the plan and the
map, for people and coding agents alike.

## Requirements

- Erlang/OTP 27 or later
- rebar3

## Layout

| Path | What it is |
|---|---|
| `AGENTS.md` | conventions and plan |
| `apps/sharps_rules/` | the game rules: pure deciders, one rule per module; calls nothing with side effects |
| `apps/sharps_league/` | league processes, the event log and timers; calls the rules |
| `apps/sharps_web/` | the web API, live updates and the static front end; calls the league |
| `test/` | project-wide checks: no comments, and the layering above |
| `reference/pp26dev/` | selected files from the PHP app, frozen at the commit named in `AGENTS.md`; read-only |
| `golden/` | recorded PHP behaviour the port must reproduce; `php golden/record.php` re-records it |
