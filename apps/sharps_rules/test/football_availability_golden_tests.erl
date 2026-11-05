-module(football_availability_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_game_is_where_the_php_put_it_test() ->
    ?assertEqual([], golden:disagreements("game_state", fun game_state/1,
                                          fun php_game_state/2)).

every_recorded_board_is_open_where_the_php_opened_it_test() ->
    ?assertEqual([], golden:disagreements("decide_availability", fun port/1, fun php/2)).

game_state(#{<<"start">> := Start, <<"completed">> := Completed, <<"now">> := Now}) ->
    football_availability:game_state(#{kickoff => kickoff(Start), completed => Completed},
                                     {utc, Now}).

php_game_state(_In, State) ->
    binary_to_existing_atom(State).

port(#{<<"snapshot">> := #{<<"teams">> := Teams, <<"opened_at">> := OpenedAt,
                           <<"now">> := Now, <<"lead">> := Lead},
       <<"input">> := #{<<"games">> := Games}}) ->
    football_availability:decide(#{teams => [team(Team) || Team <- Teams],
                                   games => [game(Game) || Game <- Games],
                                   opened_at => opened_at(OpenedAt),
                                   now => {utc, Now},
                                   kickoff_lead_seconds => Lead}).

team(#{<<"name">> := Name, <<"has_live_battle">> := LiveBattle}) ->
    #{team => Name, live_battle => LiveBattle}.

game(#{<<"home">> := Home, <<"away">> := Away, <<"start">> := Start,
       <<"completed">> := Completed, <<"week">> := Week, <<"season_type">> := Type}) ->
    #{home_team => Home, away_team => Away, kickoff => kickoff(Start),
      completed => Completed, week => Week, season_type => binary_to_existing_atom(Type)}.

kickoff(null) -> unscheduled;
kickoff(Start) -> {utc, Start}.

opened_at(null) -> no_opening_yet;
opened_at(OpenedAt) -> {utc, OpenedAt}.

php(#{<<"snapshot">> := #{<<"teams">> := Teams}}, #{<<"teams">> := Answers}) ->
    #{Name => answers(maps:get(integer_to_binary(Id), Answers))
      || #{<<"id">> := Id, <<"name">> := Name} <- Teams}.

answers(#{<<"why">> := Why, <<"why_trade">> := WhyNotTradable}) ->
    #{available => answer(Why), tradable => answer(WhyNotTradable)}.

answer(null) -> yes;
answer(<<"it is carrying a live Battle">>) -> {no, live_battle};
answer(<<"its game is in progress">>) -> {no, in_game};
answer(<<"it plays within the next 30 minutes">>) -> {no, kickoff_imminent};
answer(<<"this week's results have not been priced yet">>) -> {no, unpriced};
answer(<<"no poll has priced this week's results yet">>) -> {no, no_opening_yet}.
