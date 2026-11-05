-module(football_availability).

-rule("§6").

-export([decide/1, game_state/2]).

-export_type([utc/0, game/0, snapshot/0, answer/0, reason/0]).

-define(LONGEST_GAME_SECONDS, 8 * 3600).

-type utc() :: {utc, integer()}.

-type team() :: term().

-type game() :: #{
    home_team := team(),
    away_team := team(),
    kickoff := utc() | unscheduled,
    completed := boolean(),
    week := pos_integer(),
    season_type := regular | postseason
}.

-type snapshot() :: #{
    teams := [#{team := team(), live_battle := boolean()}],
    games := [game()],
    opened_at := utc() | no_opening_yet,
    now := utc(),
    kickoff_lead_seconds := non_neg_integer()
}.

-type reason() :: live_battle | in_game | kickoff_imminent | unpriced | no_opening_yet.

-type answer() :: yes | {no, reason()}.

-spec game_state(game(), utc()) -> upcoming | live | final.
game_state(#{kickoff := unscheduled}, _Now) ->
    upcoming;
game_state(#{kickoff := Kickoff}, Now) when Kickoff > Now ->
    upcoming;
game_state(#{completed := true}, _Now) ->
    final;
game_state(#{kickoff := {utc, Kickoff}}, {utc, Now})
  when Now - Kickoff < ?LONGEST_GAME_SECONDS ->
    live;
game_state(_GameNeverMarkedComplete, _Now) ->
    final.

-spec decide(snapshot()) -> #{team() => #{available := answer(), tradable := answer()}}.
decide(#{teams := Teams, games := Games, now := Now} = Snapshot) ->
    Scheduled = [Game || #{kickoff := {utc, _}} = Game <- Games],
    BoardStaleSince = board_stale_since(Scheduled, Now),
    maps:from_list([{Team, answers(TeamState, Scheduled, BoardStaleSince, Snapshot)}
                    || #{team := Team} = TeamState <- Teams]).

answers(#{team := Team} = TeamState, Scheduled, BoardStaleSince,
        #{now := Now, opened_at := OpenedAt, kickoff_lead_seconds := Lead}) ->
    OwnGames = [Game || Game <- Scheduled, plays_in(Team, Game)],
    Tradable = trade_lock(TeamState, OwnGames, Now, Lead),
    PlayedSince = [Kickoff || #{kickoff := Kickoff} <- OwnGames, Kickoff =< Now],
    StaleSince = latest([BoardStaleSince | PlayedSince]),
    #{tradable => Tradable,
      available => house_lock(TeamState, StaleSince, OpenedAt, Tradable)}.

plays_in(Team, #{home_team := Team}) -> true;
plays_in(Team, #{away_team := Team}) -> true;
plays_in(_Team, _Game) -> false.

trade_lock(#{live_battle := true}, _OwnGames, _Now, _Lead) ->
    {no, live_battle};
trade_lock(#{live_battle := false}, OwnGames, Now, Lead) ->
    InGame = lists:any(fun(Game) -> game_state(Game, Now) =:= live end, OwnGames),
    NextKickoff = earliest([Kickoff || #{kickoff := Kickoff} <- OwnGames, Kickoff > Now]),
    game_lock(InGame, NextKickoff, Now, Lead).

game_lock(true, _NextKickoff, _Now, _Lead) ->
    {no, in_game};
game_lock(false, {utc, NextKickoff}, {utc, Now}, Lead) when NextKickoff - Now =< Lead ->
    {no, kickoff_imminent};
game_lock(false, _NextKickoff, _Now, _Lead) ->
    yes.

house_lock(#{live_battle := true}, _StaleSince, _OpenedAt, _Tradable) ->
    {no, live_battle};
house_lock(_TeamState, {utc, _}, no_opening_yet, _Tradable) ->
    {no, no_opening_yet};
house_lock(_TeamState, {utc, _} = StaleSince, {utc, _} = OpenedAt, _Tradable)
  when StaleSince >= OpenedAt ->
    {no, unpriced};
house_lock(_TeamState, _StaleSince, _OpenedAt, Tradable) ->
    Tradable.

board_stale_since(Scheduled, Now) ->
    Regular = [Game || #{season_type := regular} = Game <- Scheduled],
    Started = [{Kickoff, Week} || #{kickoff := Kickoff, week := Week} <- Regular,
                                  Kickoff =< Now],
    WeeksAhead = [Week || #{kickoff := Kickoff, week := Week} <- Regular, Kickoff > Now],
    once_the_week_is_played(Started, WeeksAhead).

once_the_week_is_played([], _WeeksAhead) ->
    never;
once_the_week_is_played(Started, WeeksAhead) ->
    {LastKickoff, ItsWeek} = lists:max(Started),
    case [Week || Week <- WeeksAhead, Week =< ItsWeek] of
        [] -> LastKickoff;
        _StillToPlay -> never
    end.

latest(Times) ->
    case [Time || {utc, _} = Time <- Times] of
        [] -> never;
        Dated -> lists:max(Dated)
    end.

earliest([]) -> never;
earliest(Times) -> lists:min(Times).
