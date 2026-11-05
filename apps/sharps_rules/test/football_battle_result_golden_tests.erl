-module(football_battle_result_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_game_settles_as_the_php_settled_it_test() ->
    ?assertEqual([], golden:disagreements("decide_battle_result", fun port/1, fun php/2)).

port(#{<<"spread">> := Spread, <<"homePoints">> := HomePoints,
       <<"awayPoints">> := AwayPoints}) ->
    football_battle_result:decide(line(Spread), #{home_points => HomePoints,
                                                  away_points => AwayPoints}).

line(null) -> no_line_quoted;
line(Spread) -> {home_spread_tenths, round(Spread * 10)}.

php(#{<<"spread">> := null}, #{<<"result">> := <<"push">>}) ->
    {push, tied_with_no_line_quoted};
php(_In, #{<<"result">> := <<"push">>}) ->
    {push, landed_on_the_line};
php(#{<<"spread">> := null}, #{<<"result">> := Side, <<"margin">> := Margin}) ->
    {side(Side), {won_straight_up_by_points, round(abs(Margin))}};
php(_In, #{<<"result">> := Side, <<"margin">> := Margin}) ->
    {side(Side), {covered_by_tenths, round(abs(Margin) * 10)}}.

side(<<"home">>) -> home;
side(<<"away">>) -> away.
