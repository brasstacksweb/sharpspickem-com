-module(football_battle_result_tests).

-include_lib("eunit/include/eunit.hrl").

home_favored_by_three_test_() ->
    HomeFavoredByThree = {home_spread_tenths, -30},
    [
        {"winning by four covers; catches the spread read from the away side",
         ?_assertEqual({home, {covered_by_tenths, 10}},
                       decide(HomeFavoredByThree, 24, 20))},
        {"winning by exactly three is a push, not a home win; catches >= in place of >",
         ?_assertEqual({push, landed_on_the_line},
                       decide(HomeFavoredByThree, 23, 20))},
        {"winning by two loses; catches settling straight up when a line exists",
         ?_assertEqual({away, {covered_by_tenths, 10}},
                       decide(HomeFavoredByThree, 22, 20))},
        {"losing outright loses by the full margin; catches a dropped sign",
         ?_assertEqual({away, {covered_by_tenths, 60}},
                       decide(HomeFavoredByThree, 17, 20))}
    ].

real_2024_week_one_games_test_() ->
    [
        {"Georgia Tech 24-21 Florida State at +11.5: the home underdog covers by 14.5",
         ?_assertEqual({home, {covered_by_tenths, 145}},
                       decide({home_spread_tenths, 115}, 24, 21))},
        {"Nevada 24-29 SMU at +27: the home underdog loses but covers by 22",
         ?_assertEqual({home, {covered_by_tenths, 220}},
                       decide({home_spread_tenths, 270}, 24, 29))},
        {"Minnesota 17-19 North Carolina at -2.5: the away side covers by 4.5",
         ?_assertEqual({away, {covered_by_tenths, 45}},
                       decide({home_spread_tenths, -25}, 17, 19))}
    ].

half_point_lines_never_push_test() ->
    Pushes = [{Spread, HomePoints, AwayPoints}
              || Spread <- [-35, -5, 5, 35],
                 HomePoints <- lists:seq(0, 10),
                 AwayPoints <- lists:seq(0, 10),
                 decide({home_spread_tenths, Spread}, HomePoints, AwayPoints)
                     =:= {push, landed_on_the_line}],
    ?assertEqual([], Pushes).

pick_em_line_test_() ->
    PickEm = {home_spread_tenths, 0},
    [
        {"a zero line with a tied score is a push",
         ?_assertEqual({push, landed_on_the_line}, decide(PickEm, 21, 21))},
        {"a zero line is still a line, not straight up; catches treating 0 as no line",
         ?_assertEqual({home, {covered_by_tenths, 10}}, decide(PickEm, 22, 21))}
    ].

no_line_quoted_test_() ->
    [
        {"with no line the team that scored more wins straight up (Spencer's ruling)",
         ?_assertEqual({home, {won_straight_up_by_points, 7}},
                       decide(no_line_quoted, 28, 21))},
        {"with no line an away win is the away side's; catches a dropped sign",
         ?_assertEqual({away, {won_straight_up_by_points, 3}},
                       decide(no_line_quoted, 17, 20))},
        {"with no line a tie refunds rather than picking a winner",
         ?_assertEqual({push, tied_with_no_line_quoted},
                       decide(no_line_quoted, 20, 20))}
    ].

decide(Line, HomePoints, AwayPoints) ->
    football_battle_result:decide(Line, #{home_points => HomePoints,
                                          away_points => AwayPoints}).
