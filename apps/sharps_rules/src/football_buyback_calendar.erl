-module(football_buyback_calendar).

-rule("§8").
-ruled_by(spencer).

-export([warnings/1]).

-export_type([setup/0, warning/0]).

-type league_date() :: {league_local, calendar:date()}.

-type setup() :: #{
    narrows_on := league_date() | not_set,
    closes_on := league_date() | not_set,
    championship_week_starts := league_date() | unknown,
    today := league_date(),
    season := not_started | started
}.

-type warning() ::
    {closes_during_championship_week, #{closes_on := league_date(),
                                        championship_week_starts := league_date()}}
  | {already_passed, narrows_on | closes_on, league_date()}.

-spec warnings(setup()) -> [warning()].
warnings(Setup) ->
    closes_too_late(Setup) ++ dates_already_passed(Setup).

closes_too_late(#{closes_on := {league_local, _} = ClosesOn,
                  championship_week_starts := {league_local, _} = Championships})
  when ClosesOn >= Championships ->
    [{closes_during_championship_week, #{closes_on => ClosesOn,
                                         championship_week_starts => Championships}}];
closes_too_late(_Setup) ->
    [].

dates_already_passed(#{season := started}) ->
    [];
dates_already_passed(#{season := not_started, today := Today} = Setup) ->
    [{already_passed, Boundary, Date}
     || Boundary <- [narrows_on, closes_on],
        {league_local, _} = Date <- [maps:get(Boundary, Setup)],
        Date =< Today].
