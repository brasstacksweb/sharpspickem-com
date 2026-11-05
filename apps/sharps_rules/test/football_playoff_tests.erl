-module(football_playoff_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FIRST_ROUND, <<"College Football Playoff First Round Game">>).
-define(QUARTERFINAL, <<"College Football Playoff Quarterfinal at the Rose Bowl">>).
-define(SEMIFINAL, <<"College Football Playoff Semifinal at the Orange Bowl">>).
-define(CHAMPIONSHIP, <<"College Football Playoff National Championship">>).

round_of_test_() ->
    [
        {"a First Round game",
         ?_assertEqual(first_round, round_of(?FIRST_ROUND))},
        {"a Quarterfinal played at a bowl is the Quarterfinal, not a bowl",
         ?_assertEqual(quarterfinal, round_of(?QUARTERFINAL))},
        {"a Semifinal", ?_assertEqual(semifinal, round_of(?SEMIFINAL))},
        {"the National Championship",
         ?_assertEqual(championship, round_of(?CHAMPIONSHIP))},
        {"a bowl outside the Playoff pays nothing",
         ?_assertEqual(not_a_playoff_round, round_of(<<"Vrbo Fiesta Bowl">>))},
        {"a bowl naming its own national championship is not the Playoff's; catches "
         "matching the round without \"playoff\"",
         ?_assertEqual(not_a_playoff_round,
                       round_of(<<"Celebration Bowl - HBCU National Championship">>))},
        {"an unrecognised Playoff label records nothing rather than guessing",
         ?_assertEqual(not_a_playoff_round,
                       round_of(<<"College Football Playoff Showcase">>))},
        {"CFBD's capitals do not matter; catches a case-sensitive match",
         ?_assertEqual(semifinal, round_of(<<"COLLEGE FOOTBALL PLAYOFF SEMIFINAL">>))}
    ].

the_2024_bracket_test_() ->
    #{slots := Slots, waiting_on_games := Waiting} =
        football_playoff:slots(bracket_2024()),
    [
        {"fifteen slots, and nothing waiting",
         ?_assertEqual({15, 0}, {length(Slots), Waiting})},
        {"the four byes are the quarterfinalists who played no First Round game",
         ?_assertEqual([{bye, <<"Boise State">>}, {bye, <<"Arizona State">>},
                        {bye, <<"Oregon">>}, {bye, <<"Georgia">>}],
                       winners(lists:sublist(Slots, 4)))},
        {"then each round's winners, in payout order, whichever side they played on",
         ?_assertEqual([{first_round, <<"Notre Dame">>},
                        {first_round, <<"Penn State">>},
                        {first_round, <<"Texas">>},
                        {first_round, <<"Ohio State">>},
                        {quarterfinal, <<"Penn State">>},
                        {quarterfinal, <<"Texas">>},
                        {quarterfinal, <<"Ohio State">>},
                        {quarterfinal, <<"Notre Dame">>},
                        {semifinal, <<"Notre Dame">>},
                        {semifinal, <<"Ohio State">>},
                        {championship, <<"Ohio State">>}],
                       winners(lists:nthtail(4, Slots)))},
        {"a bye names the quarterfinal opponent",
         ?_assertMatch([#{team := <<"Boise State">>, opponent := <<"Penn State">>} | _],
                       Slots)},
        {"a won slot carries its game, for the score shown beside it",
         ?_assertMatch(#{game := #{home_points := 27, away_points := 17}},
                       lists:nth(5, Slots))}
    ].

the_payout_order_does_not_depend_on_the_feed_order_test() ->
    #{slots := InOrder} = football_playoff:slots(bracket_2024()),
    #{slots := Reversed} = football_playoff:slots(lists:reverse(bracket_2024())),
    ?assertEqual(lists:sort(winners(InOrder)), lists:sort(winners(Reversed))),
    ?assertEqual([bye, bye, bye, bye],
                 [Round || {Round, _Team} <- lists:sublist(winners(Reversed), 4)]),
    ?assertMatch([{championship, _}], lists:nthtail(14, winners(Reversed))).

unfinished_games_wait_test_() ->
    Kickoff = #{home_team => <<"Oregon">>, away_team => <<"Ohio State">>,
                notes => ?QUARTERFINAL, completed => false},
    InProgress = Kickoff#{home_points => 7, away_points => 3},
    [
        {"a game not yet completed pays nothing and is counted as waiting",
         ?_assertEqual(#{slots => [], waiting_on_games => 1},
                       football_playoff:slots([Kickoff]))},
        {"points on a game in progress are not a result; catches trusting the score",
         ?_assertEqual(#{slots => [], waiting_on_games => 1},
                       football_playoff:slots([InProgress]))},
        {"a bowl is neither paid nor waited on",
         ?_assertEqual(#{slots => [], waiting_on_games => 0},
                       football_playoff:slots([Kickoff#{notes := <<"Fiesta Bowl">>}]))}
    ].

round_of(Notes) ->
    football_playoff:round_of(Notes).

winners(Slots) ->
    [{Round, Team} || #{round := Round, team := Team} <- Slots].

bracket_2024() ->
    [
        final(<<"Notre Dame">>, 27, <<"Indiana">>, 17, ?FIRST_ROUND),
        final(<<"Penn State">>, 38, <<"SMU">>, 10, ?FIRST_ROUND),
        final(<<"Texas">>, 38, <<"Clemson">>, 24, ?FIRST_ROUND),
        final(<<"Ohio State">>, 42, <<"Tennessee">>, 17, ?FIRST_ROUND),
        final(<<"Boise State">>, 14, <<"Penn State">>, 31, ?QUARTERFINAL),
        final(<<"Arizona State">>, 31, <<"Texas">>, 39, ?QUARTERFINAL),
        final(<<"Oregon">>, 21, <<"Ohio State">>, 41, ?QUARTERFINAL),
        final(<<"Georgia">>, 10, <<"Notre Dame">>, 23, ?QUARTERFINAL),
        final(<<"Penn State">>, 24, <<"Notre Dame">>, 27, ?SEMIFINAL),
        final(<<"Texas">>, 14, <<"Ohio State">>, 28, ?SEMIFINAL),
        final(<<"Notre Dame">>, 23, <<"Ohio State">>, 34, ?CHAMPIONSHIP)
    ].

final(Home, HomePoints, Away, AwayPoints, Notes) ->
    #{home_team => Home, away_team => Away, home_points => HomePoints,
      away_points => AwayPoints, notes => Notes, completed => true}.
