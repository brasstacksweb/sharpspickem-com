-module(league_market).

-export([order/4, cancel/3, reorder/4]).

-export([holding/3, standing/3, available/3, sale/3, pending/2, still_holds/2, fold/2]).

-type owner() :: binary().

-type team() :: binary().

-type utc() :: {utc, integer()}.

-type kind() :: {bid, pos_integer()} | add | drop | conditional_drop | sale.

-spec order(owner(), kind(), team(), #{now := utc(), state := league_state:state()}) ->
    [league_state:event()] | {refused, term()}.
order(Owner, Kind, Team, #{now := Now, state := State}) ->
    maybe
        ok ?= market_open(Now, State),
        {ok, Board} ?= on_the_board(league_state:team(Team, State)),
        Snapshot = snapshot(Owner, Board, Now, State),
        Order = #{kind => Kind, making_room => no},
        Decision = football_market_order:decide(Order, Snapshot),
        queue_or_execute(Decision, Owner, Kind, Board, Now, State)
    end.

market_open(Now, #{draft := #{stage := complete}} = State) ->
    case league_state:season_over(Now, State) of
        true -> {refused, season_over};
        false -> ok
    end;
market_open(_Now, _BeforeOrDuringTheDraft) ->
    {refused, market_opens_after_the_draft}.

on_the_board(not_in_the_league) -> {refused, team_not_found};
on_the_board(Team) -> {ok, Team}.

queue_or_execute({refused, _Why} = Refused, _Owner, _Kind, _Team, _Now, _State) ->
    Refused;
queue_or_execute({queue, _Why}, Owner, Kind, #{team := Team}, _Now, State) ->
    [{order_queued, queued(Owner, Kind, Team, State)}];
queue_or_execute(execute, Owner, Kind, Team, Now, State) ->
    executed(Owner, Kind, Team, Now, State).

queued(Owner, Kind, Team, #{orders_created := Created} = State) ->
    {Plain, Amount, Conditional} = order_kind(Kind),
    #{number => Created + 1, owner => Owner, team => Team, kind => Plain,
      amount_units => Amount, conditional => Conditional,
      priority => priority(Plain, Owner, State)}.

order_kind({bid, Amount}) -> {bid, Amount, false};
order_kind(conditional_drop) -> {drop, none, true};
order_kind(Kind) -> {Kind, none, false}.

priority(bid, Owner, State) ->
    Ranked = [Priority || #{owner := Bidder, priority := Priority} <- pending(bid, State),
                          Bidder =:= Owner],
    lists:max([0 | Ranked]) + 1;
priority(_NotABid, _Owner, _State) ->
    0.

executed(Owner, Kind, #{team := Team} = Board, Now, State) ->
    case transfer(Owner, Kind, Board, Now, State) of
        {refused, _Why} = Refused ->
            Refused;
        Transfer ->
            Events = [Transfer, {order_executed, #{owner => Owner, team => Team}}],
            Events ++ league_battles:created(Now, fold(Events, State))
    end.

transfer(Owner, {bid, _Amount}, #{team := Team}, _Now, State) ->
    {team_bought, #{owner => Owner, team => Team,
                    price_units => league_state:market_value(Team, State)}};
transfer(Owner, add, #{team := Team}, _Now, _State) ->
    {team_added, #{owner => Owner, team => Team}};
transfer(Owner, drop, #{team := Team}, _Now, _State) ->
    {team_dropped, #{owner => Owner, team => Team}};
transfer(Owner, sale, #{team := Team} = Board, Now, State) ->
    case football_house_buyback:decide(sale(Board, Now, State)) of
        {sell, #{price_units := Price}} ->
            {team_sold, #{owner => Owner, team => Team, price_units => Price}};
        Refused ->
            Refused
    end.

snapshot(Owner, #{team := Team, owner := TeamOwner}, Now, State) ->
    Mine = [Order || #{owner := Holder, team := Ordered} = Order <- pending(any, State),
                     Holder =:= Owner, Ordered =/= Team],
    Acquiring = [Kind || #{kind := Kind} <- Mine, Kind =:= bid orelse Kind =:= add],
    Committed = lists:sum([Amount || #{kind := bid, amount_units := Amount} <- Mine]),
    #{season => running,
      you => (holding(Owner, Now, State))#{owner => Owner,
                                           committed_to_bids_units => Committed,
                                           teams_pending => length(Acquiring)},
      team => #{team => Team, owner => TeamOwner,
                rank => league_state:rank(Team, State),
                market_value_units => league_state:market_value(Team, State),
                extra_games_this_week => league_state:team_extra_games(Team, Now, State),
                available => available(Team, Now, State),
                in_pending_trade => in_a_pending_trade(Team, State),
                has_your_order => has_an_order(Owner, Team, State)},
      buyback_stage => league_state:buyback_stage(Now, State),
      max_teams => league_state:max_teams(State),
      stake_units => league_state:stake(State),
      battle_season => league_state:battle_season(Now, State)}.

has_an_order(Owner, Team, State) ->
    lists:any(fun(#{owner := Holder, team := Ordered}) ->
                      Holder =:= Owner andalso Ordered =:= Team
              end, pending(any, State)).

in_a_pending_trade(Team, State) ->
    lists:any(fun(#{team_from_a := FromA, team_from_b := FromB}) ->
                      Team =:= FromA orelse Team =:= FromB
              end, league_state:pending_trades(State)).

-spec holding(owner(), utc(), league_state:state()) ->
    #{funds_units := integer(), escrow_units := integer(),
      teams_held := non_neg_integer(), extra_games_this_week := non_neg_integer()}.
holding(Owner, Now, State) ->
    #{funds_units => league_state:funds(Owner, State),
      escrow_units => league_state:escrow(Owner, State),
      teams_held => length(league_state:held_by(Owner, State)),
      extra_games_this_week => league_state:extra_games_this_week(Owner, Now, State)}.

-spec standing(owner(), utc(), league_state:state()) -> in_good_standing | in_margin_call.
standing(Owner, Now, State) ->
    Holding = (holding(Owner, Now, State))#{
        stake_units => league_state:stake(State),
        battle_season => league_state:battle_season(Now, State)},
    {Standing, _Figures} = football_battle_reserve:margin_call(Holding),
    Standing.

-spec available(team(), utc(), league_state:state()) -> football_availability:answer().
available(Team, Now, State) ->
    #{Team := #{available := Available}} = league_state:availability(Now, State),
    Available.

-spec sale(#{team := team(), basis_units := integer(), atom() => term()}, utc(),
           league_state:state()) -> football_house_buyback:sale().
sale(#{team := Team, basis_units := Basis}, Now, State) ->
    #{team => {owned_by_seller, #{basis_units => Basis}},
      stage => league_state:buyback_stage(Now, State),
      rank => league_state:rank(Team, State),
      market_value_units => league_state:market_value(Team, State),
      house_balance_units => league_state:house_balance(State)}.

-spec pending(bid | add | sale | drop | conditional_drop | any, league_state:state()) ->
    [league_state:order()].
pending(any, State) ->
    league_state:pending_orders(State);
pending(conditional_drop, State) ->
    [Order || #{kind := drop, conditional := true} = Order <- pending(any, State)];
pending(drop, State) ->
    [Order || #{kind := drop, conditional := false} = Order <- pending(any, State)];
pending(Kind, State) ->
    [Order || #{kind := Pending} = Order <- pending(any, State), Pending =:= Kind].

-spec still_holds(league_state:order(), league_state:state()) -> boolean().
still_holds(#{owner := Owner, team := Team}, State) ->
    maps:get(owner, league_state:team(Team, State)) =:= Owner.

-spec cancel(owner(), pos_integer(), league_state:state()) -> [league_state:event()].
cancel(Owner, Number, State) ->
    case [Order || #{number := Pending, owner := Holder} = Order <- pending(any, State),
                   Pending =:= Number, Holder =:= Owner] of
        [_Mine] -> [{order_cancelled, Number}];
        [] -> []
    end.

-spec reorder(owner(), pos_integer(), up | down, league_state:state()) ->
    [league_state:event()] | {refused, not_your_pending_bid}.
reorder(Owner, Number, Direction, State) ->
    Bids = lists:sort(fun ranked_before/2,
                      [Bid || #{owner := Holder} = Bid <- pending(bid, State),
                              Holder =:= Owner]),
    case lists:search(fun(#{number := Pending}) -> Pending =:= Number end, Bids) of
        {value, Bid} -> swapped(Bid, neighbour(Bid, Direction, Bids), Direction);
        false -> {refused, not_your_pending_bid}
    end.

ranked_before(#{priority := Priority, number := Number},
              #{priority := OtherPriority, number := OtherNumber}) ->
    {Priority, Number} =< {OtherPriority, OtherNumber}.

neighbour(Bid, up, Bids) -> just_before(Bid, Bids);
neighbour(Bid, down, Bids) -> just_before(Bid, lists:reverse(Bids)).

just_before(Bid, Bids) ->
    case lists:takewhile(fun(Other) -> Other =/= Bid end, Bids) of
        [] -> at_the_end;
        Earlier -> lists:last(Earlier)
    end.

swapped(_Bid, at_the_end, _Direction) ->
    [];
swapped(#{number := Mine, priority := Same}, #{number := Theirs, priority := Same}, up) ->
    [{orders_reprioritised, [{Mine, Same - 1}, {Theirs, Same}]}];
swapped(#{number := Mine, priority := Same}, #{number := Theirs, priority := Same},
        down) ->
    [{orders_reprioritised, [{Mine, Same + 1}, {Theirs, Same}]}];
swapped(#{number := Mine, priority := MyPriority},
        #{number := Theirs, priority := TheirPriority}, _Direction) ->
    [{orders_reprioritised, [{Mine, TheirPriority}, {Theirs, MyPriority}]}].

-spec fold([league_state:event()], league_state:state()) -> league_state:state().
fold(Events, State) ->
    lists:foldl(fun league_state:apply_event/2, State, Events).
