-module(league_commands).

-export([decide/2]).

-export_type([command/0, request/0]).

-define(GAME_RUNTIME_SECONDS, 21600).

-define(COMMISSIONER_ONLY, [confirm_contribution, reject_contribution, reverse_contribution,
                            adjust_funds, settle_season]).

-type owner() :: binary().

-type command() ::
    {request_funds, integer()}
  | {cancel_fund_request, pos_integer()}
  | {confirm_contribution, pos_integer(), as_requested | integer()}
  | {reject_contribution, pos_integer()}
  | {reverse_contribution, pos_integer()}
  | {adjust_funds, owner(), integer(), Reason :: binary()}
  | {order, {bid, pos_integer()} | add | drop | conditional_drop | sale, binary()}
  | {cancel_order, pos_integer()}
  | {reorder_bid, pos_integer(), up | down}
  | {propose_trade, map()}
  | {confirm_trade, pos_integer()}
  | {cancel_trade, pos_integer()}
  | {raise_stake, pos_integer(), pos_integer()}
  | {answer_raise, pos_integer(), accept | decline}
  | settle_season
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
    case lists:member(name(Command), ?COMMISSIONER_ONLY) andalso Owner =/= Commissioner of
        true -> {refused, not_the_commissioner};
        false -> as_events(command(Command, Actor, Request, State))
    end.

name(Command) when is_atom(Command) -> Command;
name(Command) when is_tuple(Command) -> element(1, Command).

as_events({refused, _Why} = Refused) -> Refused;
as_events(Events) when is_list(Events) -> {ok, Events}.

command({order, Kind, Team}, #{owner := Owner}, #{at := Now}, State) ->
    league_market:order(Owner, Kind, Team, #{now => Now, state => State});
command({cancel_order, Number}, #{owner := Owner}, _Request, State) ->
    league_market:cancel(Owner, Number, State);
command({reorder_bid, Number, Direction}, #{owner := Owner}, _Request, State) ->
    league_market:reorder(Owner, Number, Direction, State);
command({propose_trade, Proposal}, #{owner := Owner}, #{at := Now}, State) ->
    league_trades:propose(Owner, Proposal, #{now => Now, state => State});
command({confirm_trade, Number}, #{owner := Owner}, #{at := Now}, State) ->
    league_trades:confirm(Owner, Number, #{now => Now, state => State});
command({cancel_trade, Number}, #{owner := Owner}, _Request, State) ->
    league_trades:cancel(Owner, Number, State);
command({raise_stake, Number, Stake}, #{owner := Owner}, #{at := Now}, State) ->
    league_battles:raise(Owner, Number, Stake, #{now => Now, state => State});
command({answer_raise, Number, Answer}, #{owner := Owner}, #{at := Now}, State) ->
    league_battles:answer(Owner, Number, Answer, #{now => Now, state => State});
command({request_funds, Units}, #{owner := Owner}, _Request,
        #{season_settled := Settled, settings := Settings} = State) ->
    case contribution:request(
           #{season_settled => Settled,
             top_ups_enabled => maps:get(top_ups_enabled, Settings, true),
             amount_units => Units,
             already_pending => league_state:pending_contribution(Owner, State) =/= none}) of
        requested -> [{contribution_requested, #{owner => Owner, units => Units}}];
        Refused -> Refused
    end;
command({cancel_fund_request, Number}, #{owner := Owner}, _Request, State) ->
    case contribution:cancel(Owner, league_state:contribution(Number, State)) of
        cancelled -> [{contribution_cancelled, Number}];
        unchanged -> []
    end;
command({confirm_contribution, Number, Amount}, _Commissioner, _Request,
        #{season_settled := Settled} = State) ->
    case contribution:confirm(#{season_settled => Settled,
                                contribution => league_state:contribution(Number, State),
                                amount_units => Amount}) of
        {confirm, Units} -> [{contribution_confirmed, Number, Units}];
        Refused -> Refused
    end;
command({reject_contribution, Number}, _Commissioner, _Request, State) ->
    case contribution:reject(league_state:contribution(Number, State)) of
        rejected -> [{contribution_rejected, Number}];
        unchanged -> []
    end;
command({reverse_contribution, Number}, _Commissioner, _Request,
        #{season_settled := Settled} = State) ->
    case contribution:reverse(#{season_settled => Settled,
                                contribution => league_state:contribution(Number, State)}) of
        {reverse, Units} -> [{contribution_reversed, Number, Units}];
        Refused -> Refused
    end;
command({adjust_funds, Owner, Units, Reason}, _Commissioner, _Request,
        #{season_settled := Settled, owners := Owners}) ->
    case adjustment:decide(#{amount_units => Units, reason => Reason,
                             in_the_league => is_map_key(Owner, Owners),
                             season_settled => Settled}) of
        {adjust, Adjusted, Stated} ->
            [{funds_adjusted, #{owner => Owner, units => Adjusted, reason => Stated}}];
        Refused -> Refused
    end;
command(settle_season, _Commissioner, _Request, State) ->
    settlement(football_season_settlement:decide(season(State)));
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

season(#{owners := Owners, owner_order := Order, season_settled := Settled} = State) ->
    Slots = lists:sum([Games || {_Round, _Share, Games}
                                    <- football_playoff_payout:schedule()]),
    #{prize_pool => case league_state:prize_pool(State) of
                        not_frozen -> not_frozen;
                        _Pool -> frozen
                    end,
      slots_outstanding => max(0, Slots - length(league_state:playoff_slots(State))),
      house_units => league_state:house_balance(State),
      contributions_pending => league_state:contributions_pending(State),
      settled => Settled,
      balances => [{Owner, Funds} || Owner <- Order,
                                     #{funds_units := Funds} <- [maps:get(Owner, Owners)]]}.

settlement({settle, Payments}) -> [{season_settled, Payments}];
settlement({refused, _Why} = Refused) -> Refused.
