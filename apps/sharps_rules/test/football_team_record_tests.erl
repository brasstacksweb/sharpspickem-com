-module(football_team_record_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONFERENCES, #{
    <<"Indiana">> => <<"Big Ten">>, <<"UCLA">> => <<"Big Ten">>,
    <<"Maryland">> => <<"Big Ten">>, <<"Northwestern">> => <<"Big Ten">>,
    <<"Nebraska">> => <<"Big Ten">>, <<"Washington">> => <<"Big Ten">>,
    <<"Michigan State">> => <<"Big Ten">>, <<"Michigan">> => <<"Big Ten">>,
    <<"Ohio State">> => <<"Big Ten">>, <<"Purdue">> => <<"Big Ten">>,
    <<"Oregon">> => <<"Big Ten">>, <<"Penn State">> => <<"Big Ten">>,
    <<"Florida International">> => <<"Conference USA">>,
    <<"Charlotte">> => <<"American Athletic">>,
    <<"UConn">> => independent, <<"UMass">> => independent
}).

indiana_2024_regular_season_test_() ->
    Record = record(<<"Indiana">>, [
        game(<<"Indiana">>, 31, <<"Florida International">>, 7, -205),
        game(<<"UCLA">>, 13, <<"Indiana">>, 42, 25),
        game(<<"Indiana">>, 52, <<"Charlotte">>, 14, -285),
        game(<<"Indiana">>, 42, <<"Maryland">>, 28, -75),
        game(<<"Northwestern">>, 24, <<"Indiana">>, 41, 125),
        game(<<"Indiana">>, 56, <<"Nebraska">>, 7, -65),
        game(<<"Indiana">>, 31, <<"Washington">>, 17, -55),
        game(<<"Michigan State">>, 10, <<"Indiana">>, 47, 75),
        game(<<"Indiana">>, 20, <<"Michigan">>, 15, -145),
        game(<<"Ohio State">>, 38, <<"Indiana">>, 15, -105),
        game(<<"Indiana">>, 66, <<"Purdue">>, 0, -285)
    ]),
    [
        {"10-1 overall in the cached fixture",
         ?_assertMatch(#{won := 10, lost := 1}, Record)},
        {"8-1 in the Big Ten; catches counting Charlotte or FIU as conference games",
         ?_assertMatch(#{conference_won := 8, conference_lost := 1}, Record)},
        {"9-2 against the spread: short of 14.5 against Michigan, beaten at Ohio State",
         ?_assertMatch(#{covered := 9, missed := 2, pushed := 0}, Record)},
        {"one row per game, in the order given",
         ?_assertMatch(#{games := [#{result := won} | _]}, Record)},
        {"the Ohio State loss is the tenth row",
         ?_assertMatch(#{result := lost, against_the_spread := missed},
                       lists:nth(10, maps:get(games, Record)))}
    ].

won_or_lost_from_the_teams_side_test_() ->
    [
        {"a home win",
         ?_assertMatch(#{result := won},
                       row(<<"Indiana">>, game(<<"Indiana">>, 31, <<"Purdue">>, 17)))},
        {"an away win; catches reading the score from the home side",
         ?_assertMatch(#{result := won},
                       row(<<"Indiana">>, game(<<"Purdue">>, 17, <<"Indiana">>, 31)))},
        {"an away loss",
         ?_assertMatch(#{result := lost},
                       row(<<"Indiana">>, game(<<"Purdue">>, 31, <<"Indiana">>, 17)))}
    ].

a_tie_counts_toward_no_record_test() ->
    ?assertMatch(#{won := 0, lost := 0, conference_won := 0, conference_lost := 0,
                   games := [#{result := tied}]},
                 record(<<"Indiana">>, [game(<<"Indiana">>, 20, <<"Purdue">>, 20)])).

conference_games_test_() ->
    Rivals = game(<<"Indiana">>, 31, <<"Purdue">>, 17),
    AgainstFcs = game(<<"Indiana">>, 52, <<"Western Illinois">>, 3),
    Independents = game(<<"UConn">>, 47, <<"UMass">>, 42),
    BigTenChampionship = (game(<<"Oregon">>, 45, <<"Penn State">>, 37, -35))#{
        notes := <<"Big Ten Championship">>},
    RoseBowl = (game(<<"Ohio State">>, 41, <<"Oregon">>, 21, 25))#{
        season_type := postseason},
    [
        {"two Big Ten teams in the regular season",
         ?_assertMatch(#{conference_game := true}, row(<<"Indiana">>, Rivals))},
        {"an opponent missing from the league's teams (FCS) counts overall only",
         ?_assertMatch(#{won := 1, conference_won := 0},
                       record(<<"Indiana">>, [AgainstFcs]))},
        {"two independents are not rivals; catches matching independent to itself",
         ?_assertMatch(#{conference_game := false}, row(<<"UConn">>, Independents))},
        {"Oregon 45-37 Penn State, the Big Ten Championship, is not a conference game",
         ?_assertMatch(#{conference_game := false},
                       row(<<"Oregon">>, BigTenChampionship))},
        {"the notes match in any case; catches a case-sensitive search",
         ?_assertMatch(#{conference_game := false},
                       row(<<"Indiana">>, Rivals#{notes := <<"BIG TEN CHAMPIONSHIP">>}))},
        {"Ohio State 41-21 Oregon in the Rose Bowl: Big Ten teams in the postseason",
         ?_assertMatch(#{conference_game := false}, row(<<"Ohio State">>, RoseBowl))}
    ].

against_the_spread_test_() ->
    IndianaFavoredAtUcla = game(<<"UCLA">>, 13, <<"Indiana">>, 42, 25),
    IndianaWinsByTheLine = game(<<"Indiana">>, 24, <<"Purdue">>, 17, -70),
    TiedWithIndianaFavored = game(<<"Indiana">>, 20, <<"Purdue">>, 20, -35),
    NoLine = game(<<"Indiana">>, 31, <<"Purdue">>, 17),
    [
        {"an away favorite covering covers; catches reading the line from the home side",
         ?_assertMatch(#{against_the_spread := covered},
                       row(<<"Indiana">>, IndianaFavoredAtUcla))},
        {"the home team on the other side of that line missed",
         ?_assertMatch(#{against_the_spread := missed},
                       row(<<"UCLA">>, IndianaFavoredAtUcla))},
        {"winning by exactly the line is a push",
         ?_assertMatch(#{covered := 0, missed := 0, pushed := 1},
                       record(<<"Indiana">>, [IndianaWinsByTheLine]))},
        {"a tie can still cover the line",
         ?_assertMatch(#{result := tied, against_the_spread := covered},
                       row(<<"Purdue">>, TiedWithIndianaFavored))},
        {"no line is no cover, not a straight-up win; catches settling it like a Battle",
         ?_assertMatch(#{covered := 0, missed := 0, pushed := 0,
                         games := [#{against_the_spread := no_line_quoted}]},
                       record(<<"Indiana">>, [NoLine]))}
    ].

record(Team, Games) ->
    football_team_record:decide(Team, Games, ?CONFERENCES).

row(Team, Game) ->
    #{games := [Row]} = record(Team, [Game]),
    Row.

game(Home, HomePoints, Away, AwayPoints) ->
    game(Home, HomePoints, Away, AwayPoints, no_line_quoted).

game(Home, HomePoints, Away, AwayPoints, HomeSpreadTenths) ->
    #{home_team => Home, away_team => Away,
      home_points => HomePoints, away_points => AwayPoints,
      line => line(HomeSpreadTenths), season_type => regular, notes => <<>>}.

line(no_line_quoted) -> no_line_quoted;
line(HomeSpreadTenths) -> {home_spread_tenths, HomeSpreadTenths}.
