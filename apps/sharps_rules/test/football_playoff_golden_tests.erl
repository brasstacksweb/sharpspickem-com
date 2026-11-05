-module(football_playoff_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_bracket_earns_the_slots_the_php_found_test() ->
    ?assertEqual([], golden:disagreements("decide_playoff_slots", fun port/1, fun php/2)).

port(#{<<"games">> := Games}) ->
    #{slots := Slots} = Found = football_playoff:slots([game(Game) || Game <- Games]),
    Found#{slots := [maps:without([game], Slot) || Slot <- Slots]}.

game(#{<<"home">> := Home, <<"away">> := Away, <<"completed">> := Completed,
       <<"notes">> := Notes} = Game) ->
    Points = #{home_points => maps:get(<<"home_points">>, Game),
               away_points => maps:get(<<"away_points">>, Game)},
    maps:merge(#{home_team => Home, away_team => Away, completed => Completed,
                 notes => Notes},
               maps:filter(fun(_Side, Scored) -> Scored =/= null end, Points)).

php(_In, #{<<"slots">> := Slots, <<"skipped_incomplete">> := Waiting}) ->
    #{slots => [slot(Slot) || Slot <- Slots], waiting_on_games => Waiting}.

slot(#{<<"round">> := Round, <<"team">> := Team, <<"opponent">> := Opponent}) ->
    #{round => binary_to_existing_atom(Round), team => Team, opponent => Opponent}.
