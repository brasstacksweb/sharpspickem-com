-module(football_buyback_calendar_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_calendar_warns_as_the_php_did_test() ->
    ?assertEqual([], golden:disagreements("decide_calendar_warnings", fun port/1,
                                          fun php/2)).

port(#{<<"s">> := #{<<"narrows">> := NarrowsOn, <<"closes">> := ClosesOn,
                    <<"today">> := Today, <<"championships">> := Championships,
                    <<"season_started">> := Started}}) ->
    football_buyback_calendar:warnings(#{narrows_on => set_or_not(NarrowsOn),
                                         closes_on => set_or_not(ClosesOn),
                                         championship_week_starts =>
                                             known_or_not(Championships),
                                         today => league_date(Today),
                                         season => season(Started)}).

set_or_not(<<>>) -> not_set;
set_or_not(Date) -> league_date(Date).

known_or_not(null) -> unknown;
known_or_not(Date) -> league_date(Date).

season(true) -> started;
season(false) -> not_started.

php(#{<<"s">> := Setup}, Warnings) ->
    [warning(Key, Setup) || #{<<"key">> := Key} <- Warnings].

warning(<<"closes_after_championships">>, #{<<"closes">> := ClosesOn,
                                            <<"championships">> := Championships}) ->
    {closes_during_championship_week,
     #{closes_on => league_date(ClosesOn),
       championship_week_starts => league_date(Championships)}};
warning(<<"narrows_already_passed">>, #{<<"narrows">> := NarrowsOn}) ->
    {already_passed, narrows_on, league_date(NarrowsOn)};
warning(<<"closes_already_passed">>, #{<<"closes">> := ClosesOn}) ->
    {already_passed, closes_on, league_date(ClosesOn)}.

league_date(<<Year:4/binary, "-", Month:2/binary, "-", Day:2/binary>>) ->
    {league_local, {binary_to_integer(Year), binary_to_integer(Month),
                    binary_to_integer(Day)}}.
