-module(football_team_record).

-export([decide/3]).

-export_type([team/0, conference/0, conference_of/0, game/0, season_record/0]).

-type team() :: binary().

-type conference() :: binary() | independent.

-type conference_of() :: #{team() => conference()}.

-type game() :: #{
    home_team := team(),
    away_team := team(),
    home_points := non_neg_integer(),
    away_points := non_neg_integer(),
    line := football_battle_result:line(),
    season_type := regular | postseason,
    notes := binary()
}.

-type result() :: won | lost | tied.

-type against_the_spread() :: covered | missed | pushed | no_line_quoted.

-type game_row() :: #{
    result := result(),
    conference_game := boolean(),
    against_the_spread := against_the_spread()
}.

-type season_record() :: #{
    won := non_neg_integer(),
    lost := non_neg_integer(),
    conference_won := non_neg_integer(),
    conference_lost := non_neg_integer(),
    covered := non_neg_integer(),
    missed := non_neg_integer(),
    pushed := non_neg_integer(),
    games := [game_row()]
}.

-spec decide(team(), [game()], conference_of()) -> season_record().
decide(Team, Games, ConferenceOf) ->
    Rows = [row(Team, Game, ConferenceOf) || Game <- Games],
    ConferenceRows = [Row || #{conference_game := true} = Row <- Rows],
    #{won => count(result, won, Rows),
      lost => count(result, lost, Rows),
      conference_won => count(result, won, ConferenceRows),
      conference_lost => count(result, lost, ConferenceRows),
      covered => count(against_the_spread, covered, Rows),
      missed => count(against_the_spread, missed, Rows),
      pushed => count(against_the_spread, pushed, Rows),
      games => Rows}.

count(Key, Value, Rows) ->
    length([Row || Row <- Rows, map_get(Key, Row) =:= Value]).

row(Team, Game, ConferenceOf) ->
    {Side, Opponent} = side_and_opponent(Team, Game),
    #{result => result(Side, Game),
      conference_game => conference_game(Team, Opponent, Game, ConferenceOf),
      against_the_spread => against_the_spread(Side, Game)}.

side_and_opponent(Team, #{home_team := Team, away_team := Opponent}) -> {home, Opponent};
side_and_opponent(Team, #{away_team := Team, home_team := Opponent}) -> {away, Opponent}.

result(home, #{home_points := Scored, away_points := Allowed}) ->
    by_margin(Scored - Allowed);
result(away, #{away_points := Scored, home_points := Allowed}) ->
    by_margin(Scored - Allowed).

by_margin(Margin) when Margin > 0 -> won;
by_margin(Margin) when Margin < 0 -> lost;
by_margin(0) -> tied.

against_the_spread(_Side, #{line := no_line_quoted}) ->
    no_line_quoted;
against_the_spread(Side, #{line := Line} = Game) ->
    covered_missed_or_pushed(Side, football_battle_result:decide(Line, Game)).

covered_missed_or_pushed(Side, {Side, _CoveredBy}) -> covered;
covered_missed_or_pushed(_Side, {push, _LandedOnTheLine}) -> pushed;
covered_missed_or_pushed(_Side, {_OtherSide, _CoveredBy}) -> missed.

conference_game(Team, Opponent, Game, ConferenceOf) ->
    same_conference(conference(Team, ConferenceOf), conference(Opponent, ConferenceOf))
        andalso on_the_conference_schedule(Game).

conference(Team, ConferenceOf) ->
    maps:get(Team, ConferenceOf, outside_the_league).

same_conference(independent, _Opponent) -> false;
same_conference(outside_the_league, _Opponent) -> false;
same_conference(Conference, Conference) -> true;
same_conference(_Conference, _OtherConference) -> false.

on_the_conference_schedule(#{season_type := postseason}) ->
    false;
on_the_conference_schedule(#{notes := Notes}) ->
    string:find(string:casefold(Notes), <<"championship">>) =:= nomatch.
