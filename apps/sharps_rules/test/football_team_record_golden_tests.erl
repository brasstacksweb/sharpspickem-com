-module(football_team_record_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_season_record_counts_as_the_php_counted_it_test() ->
    ?assertEqual([], golden:disagreements("decide_team_record", fun port/1, fun php/2)).

port(#{<<"team">> := Team, <<"games">> := Games, <<"confOf">> := ConfOf}) ->
    Record = football_team_record:decide(casefold(Team), [game(Game) || Game <- Games],
                                         conference_of(ConfOf)),
    Record#{games := [maps:without([conference_game], Row)
                      || Row <- maps:get(games, Record)]}.

game(#{<<"home_team">> := Home, <<"away_team">> := Away, <<"home_points">> := HomePoints,
       <<"away_points">> := AwayPoints, <<"spread">> := Spread,
       <<"season_type">> := SeasonType, <<"notes">> := Notes}) ->
    #{home_team => casefold(Home), away_team => casefold(Away),
      home_points => HomePoints, away_points => AwayPoints, line => line(Spread),
      season_type => binary_to_existing_atom(SeasonType), notes => Notes}.

line(null) -> no_line_quoted;
line(Spread) -> {home_spread_tenths, round(Spread * 10)}.

conference_of(ConfOf) ->
    #{Team => conference(Conference) || Team := Conference <- ConfOf}.

conference(<<"FBS Independents">>) -> independent;
conference(Conference) -> Conference.

casefold(Team) ->
    string:casefold(Team).

php(_In, #{<<"w">> := Won, <<"l">> := Lost, <<"conf_w">> := ConferenceWon,
           <<"conf_l">> := ConferenceLost, <<"ats_w">> := Covered, <<"ats_l">> := Missed,
           <<"ats_p">> := Pushed, <<"rows">> := Rows}) ->
    #{won => Won, lost => Lost, conference_won => ConferenceWon,
      conference_lost => ConferenceLost, covered => Covered, missed => Missed,
      pushed => Pushed, games => [row(Row) || Row <- Rows]}.

row(#{<<"result">> := Result, <<"ats">> := AgainstTheSpread}) ->
    #{result => result(Result),
      against_the_spread => against_the_spread(AgainstTheSpread)}.

result(<<"W">>) -> won;
result(<<"L">>) -> lost;
result(<<"T">>) -> tied.

against_the_spread(null) -> no_line_quoted;
against_the_spread(<<"covered">>) -> covered;
against_the_spread(<<"missed">>) -> missed;
against_the_spread(<<"push">>) -> pushed.
