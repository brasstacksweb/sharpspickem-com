-module(football_playoff).

-rule("§12").

-export([round_of/1, slots/1]).

-export_type([round/0, game/0, slot/0]).

-type team() :: binary().

-type round() :: first_round | quarterfinal | semifinal | championship.

-type game() :: #{
    home_team := team(),
    away_team := team(),
    notes := binary(),
    completed := boolean(),
    home_points => non_neg_integer(),
    away_points => non_neg_integer()
}.

-type slot() :: #{
    round := bye | round(),
    team := team(),
    opponent := team(),
    game => game()
}.

-spec round_of(binary()) -> round() | not_a_playoff_round.
round_of(Notes) ->
    CasefoldedNotes = string:casefold(Notes),
    playoff_round(mentions(CasefoldedNotes, <<"playoff">>), CasefoldedNotes).

playoff_round(false, _Notes) ->
    not_a_playoff_round;
playoff_round(true, Notes) ->
    first_round_named(Notes, [{<<"first round">>, first_round},
                              {<<"quarter">>, quarterfinal},
                              {<<"semifin">>, semifinal},
                              {<<"national">>, championship}]).

first_round_named(_Notes, []) ->
    not_a_playoff_round;
first_round_named(Notes, [{Label, Round} | LaterLabels]) ->
    case mentions(Notes, Label) of
        true -> Round;
        false -> first_round_named(Notes, LaterLabels)
    end.

mentions(Notes, Label) ->
    string:find(Notes, Label) =/= nomatch.

-spec slots([game()]) -> #{slots := [slot()], waiting_on_games := non_neg_integer()}.
slots(Games) ->
    PlayoffGames = [{Round, Game} || #{notes := Notes} = Game <- Games,
                                     Round <- [round_of(Notes)],
                                     Round =/= not_a_playoff_round],
    Finished = [{Round, Game} || {Round, Game} <- PlayoffGames, is_final(Game)],
    Won = [won(Round, Game) || Round <- rounds_in_payout_order(),
                               {GameRound, Game} <- Finished,
                               GameRound =:= Round],
    #{slots => byes(Finished) ++ Won,
      waiting_on_games => length(PlayoffGames) - length(Finished)}.

rounds_in_payout_order() ->
    [first_round, quarterfinal, semifinal, championship].

is_final(#{completed := true, home_points := _, away_points := _}) -> true;
is_final(_StillBeingPlayed) -> false.

byes(Finished) ->
    PlayedTheFirstRound = [Team || {first_round, Game} <- Finished, Team <- teams(Game)],
    [#{round => bye, team => Team, opponent => Opponent}
     || {quarterfinal, #{home_team := Home, away_team := Away}} <- Finished,
        {Team, Opponent} <- [{Home, Away}, {Away, Home}],
        not lists:member(Team, PlayedTheFirstRound)].

teams(#{home_team := Home, away_team := Away}) ->
    [Home, Away].

won(Round, #{home_team := Home, away_team := Away,
             home_points := HomePoints, away_points := AwayPoints} = Game)
  when HomePoints > AwayPoints ->
    #{round => Round, team => Home, opponent => Away, game => Game};
won(Round, #{home_team := Home, away_team := Away,
             home_points := HomePoints, away_points := AwayPoints} = Game)
  when AwayPoints > HomePoints ->
    #{round => Round, team => Away, opponent => Home, game => Game}.
