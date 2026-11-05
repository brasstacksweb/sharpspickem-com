-module(league_commands).

-export([decide/2]).

-export_type([command/0, request/0]).

-define(GAME_RUNTIME_SECONDS, 21600).

-type owner() :: binary().

-type command() ::
    {confirm_contribution, owner(), pos_integer()}
  | create_draft
  | {set_draft_order, [owner()]}
  | start_draft
  | {draft_select, binary()}
  | draft_pass
  | undo_pick.

-type request() :: #{at := {utc, integer()}, actor := owner(), command := command()}.

-spec decide(request(), league_state:state()) ->
    {ok, [league_state:event()]} | {refused, term()}.
decide(#{actor := Owner, command := Command} = Request,
       #{commissioner := Commissioner} = State) ->
    Actor = #{owner => Owner, commissioner => Owner =:= Commissioner},
    as_events(command(Command, Actor, Request, State)).

as_events({refused, _Why} = Refused) -> Refused;
as_events(Events) when is_list(Events) -> {ok, Events}.

command({confirm_contribution, _Owner, _Units}, #{commissioner := false}, _Request,
        _State) ->
    {refused, not_the_commissioner};
command({confirm_contribution, Owner, Units}, _Commissioner, _Request, _State) ->
    [{contribution_confirmed, #{owner => Owner, units => Units}}];
command(create_draft, Actor, _Request, #{draft := Draft, owners := Owners}) ->
    case football_draft:create(Actor, Draft) of
        {created, _NoOrderYet} -> [{draft_created, #{order => in_name_order(Owners)}}];
        Refused -> Refused
    end;
command({set_draft_order, Order}, Actor, _Request, #{draft := Draft}) ->
    case football_draft:set_order(Actor, Draft, Order) of
        {order_set, Set} -> [{draft_order_set, Set}];
        Refused -> Refused
    end;
command(start_draft, Actor, _Request, #{draft := Draft, settings := Settings}) ->
    case football_draft:start(Actor, #{draft => Draft,
                                       buyback_dates => buyback_dates(Settings)}) of
        started -> [draft_started];
        Refused -> Refused
    end;
command({draft_select, Team}, Actor, #{at := Now}, #{draft := Draft} = State) ->
    Rosters = rosters(State),
    case football_draft:select(Actor, selection(Team, Now, Draft, Rosters, State)) of
        {drafted, Pick} -> [{team_drafted, Pick, stage_after_pick(Pick, Draft, Rosters)}];
        Refused -> Refused
    end;
command(draft_pass, Actor, _Request, #{draft := #{} = Draft} = State) ->
    case football_draft:pass(Actor, Draft, rosters(State)) of
        {passed, Owner, Stage} -> [{draft_passed, Owner, Stage}];
        Refused -> Refused
    end;
command(draft_pass, _Actor, _Request, #{draft := no_draft}) ->
    {refused, no_draft_in_progress};
command(undo_pick, Actor, _Request, #{draft := Draft}) ->
    case football_draft:undo(Actor, Draft) of
        {undone, Pick, Slot} -> [{draft_pick_undone, Pick, Slot}];
        Refused -> Refused
    end.

in_name_order(Owners) ->
    lists:sort(maps:keys(Owners)).

buyback_dates(#{buyback_narrows_on := {league_local, _},
                buyback_closes_on := {league_local, _}}) ->
    set;
buyback_dates(#{}) ->
    not_set.

rosters(#{settings := #{max_teams := MaxTeams}} = State) ->
    #{teams_held => league_state:teams_held(State), max_teams => MaxTeams}.

selection(Team, Now, Draft, #{teams_held := TeamsHeld, max_teams := MaxTeams} = Rosters,
          State) ->
    OnTheClock = football_draft:on_the_clock(Draft),
    #{draft => Draft,
      team => priced(league_state:team(Team, State), State),
      rosters => Rosters,
      holding => #{funds_units => funds_of(OnTheClock, State),
                   cash_out_units => 0,
                   escrow_units => 0,
                   teams_held => maps:get(OnTheClock, TeamsHeld, 0),
                   teams_gained => 1,
                   max_teams => MaxTeams,
                   extra_games_this_week => extra_games(OnTheClock, Now, State),
                   stake_units => stake(State),
                   battle_season => battle_season(Now, State)}}.

priced(not_in_the_league, _State) ->
    not_in_the_league;
priced(#{team := Name} = Team, State) ->
    Team#{price_units => league_state:market_value(Name, State)}.

funds_of(no_one, _State) -> 0;
funds_of(Owner, State) -> league_state:funds(Owner, State).

extra_games(no_one, _Now, _State) -> 0;
extra_games(Owner, Now, State) -> league_state:extra_games_this_week(Owner, Now, State).

stake(#{settings := #{stake_units := Stake}}) -> Stake.

battle_season(Now, #{schedule := Schedule}) ->
    case [Game || #{kickoff := {utc, Kickoff}} = Game <- Schedule,
                  {utc, Kickoff + ?GAME_RUNTIME_SECONDS} > Now] of
        [] when Schedule =/= [] -> battles_over;
        _StillToPlay -> battles_being_created
    end.

stage_after_pick(#{owner := Owner}, #{stage := {picking, Slot}} = Draft,
                 #{teams_held := TeamsHeld} = Rosters) ->
    HeldAfter = TeamsHeld#{Owner => maps:get(Owner, TeamsHeld, 0) + 1},
    AfterThePick = Rosters#{teams_held := HeldAfter},
    football_draft:next(Draft, Slot, AfterThePick).
