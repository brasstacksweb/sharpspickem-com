-module(league_opening).

-export([settle/3]).

-import(league_market, [holding/3, available/3, sale/3, pending/2, still_holds/2,
                        fold/2]).

-type utc() :: {utc, integer()}.

-type number_() :: pos_integer().

-type step() :: {[league_state:event()], Rolled :: [number_()]}.

-spec settle(league_state:opening(), utc(), league_state:state()) ->
    [league_state:event()].
settle(Opening, Now, State) ->
    case league_state:season_over(Now, State) of
        true -> closed(pending(any, State)) ++ [{opening_settled, Opening}];
        false -> settled(Opening, Now, State)
    end.

settled(Opening, Now, State) ->
    Steps = [drops, sales, trades, bids, adds, battles],
    {Events, Rolled, Settled} =
        lists:foldl(fun(Step, {SoFar, RolledSoFar, Before}) ->
                            {New, NewlyRolled} = step(Step, Now, Before),
                            {SoFar ++ New, RolledSoFar ++ NewlyRolled, fold(New, Before)}
                    end, {[], [], State}, Steps),
    NotRolled = [Order || #{number := Number} = Order <- pending(any, Settled),
                          not lists:member(Number, Rolled)],
    Events ++ closed(NotRolled) ++ [{opening_settled, Opening}].

-spec step(drops | sales | trades | bids | adds | battles, utc(), league_state:state()) ->
    step().
step(drops, Now, State) -> one_by_one(drop, Now, pending(drop, State), State);
step(sales, Now, State) -> one_by_one(sale, Now, pending(sale, State), State);
step(trades, Now, State) -> one_by_one(trade, Now, confirmed_trades(State), State);
step(bids, Now, State) -> bids(Now, State);
step(adds, Now, State) -> one_by_one(add, Now, pending(add, State), State);
step(battles, Now, State) -> battles(Now, State).

decide(drop, Order, Now, State) -> drop(Order, Now, State);
decide(sale, Order, Now, State) -> sale_order(Order, Now, State);
decide(trade, Trade, Now, State) -> {league_trades:settle(Trade, Now, State), []};
decide(add, Order, Now, State) -> add(Order, Now, State).

drop(#{number := Number, owner := Owner, team := Team} = Order, Now, State) ->
    case {still_holds(Order, State), available(Team, Now, State)} of
        {false, _Available} -> {[{order_closed, Number}], []};
        {true, {no, _Why}} -> {[], [Number]};
        {true, yes} -> {[{team_dropped, #{owner => Owner, team => Team}},
                         {order_closed, Number}], []}
    end.

sale_order(#{number := Number, team := Team} = Order, Now, State) ->
    Stage = league_state:buyback_stage(Now, State),
    Rank = league_state:rank(Team, State),
    case {still_holds(Order, State), outside_the_buyback(Stage, Rank),
          available(Team, Now, State)} of
        {false, _Outside, _Available} -> {[{order_closed, Number}], []};
        {true, true, _Available} -> {[{order_closed, Number}], []};
        {true, false, {no, _Why}} -> {[], [Number]};
        {true, false, yes} -> {sold(Order, Now, State), []}
    end.

outside_the_buyback(_Stage, unranked) -> false;
outside_the_buyback(Stage, Rank) -> football_house_buyback:will_buy(Stage, Rank) =/= yes.

sold(#{number := Number, owner := Owner, team := Team}, Now, State) ->
    case house_buys(Team, Now, State) of
        {sell, #{price_units := Price}} ->
            [{team_sold, #{owner => Owner, team => Team, price_units => Price}},
             {order_closed, Number}];
        {refused, _Why} ->
            [{order_closed, Number}]
    end.

confirmed_trades(State) ->
    [Trade || #{confirmed := true} = Trade <- league_state:pending_trades(State)].

-spec bids(utc(), league_state:state()) -> step().
bids(Now, State) ->
    case pending(bid, State) of
        [] -> {[], []};
        Bids -> bids(Bids, Now, State)
    end.

bids(Bids, Now, State) ->
    Ranked = [Bid || Bid <- Bids, ranked(Bid, State)],
    {Open, Held} = lists:partition(fun(Bid) -> on_the_board(Bid, Now, State) end, Ranked),
    HeldBidders = lists:usort([Owner || #{owner := Owner} <- Held]),
    {Drops, WaitingDrops} = conditional_drops(HeldBidders, Now, State),
    {auction(Open, Drops, Now, State), numbers(Held) ++ numbers(WaitingDrops)}.

ranked(#{team := Team}, State) ->
    league_state:rank(Team, State) =/= unranked.

on_the_board(#{team := Team}, Now, State) ->
    available(Team, Now, State) =:= yes.

conditional_drops(HeldBidders, Now, State) ->
    Held = [Drop || Drop <- pending(conditional_drop, State), still_holds(Drop, State)],
    {Usable, OffTheBoard} =
        lists:partition(fun(Drop) -> on_the_board(Drop, Now, State) end, Held),
    Waiting = [Drop || #{owner := Owner} = Drop <- OffTheBoard,
                       lists:member(Owner, HeldBidders)],
    {maps:groups_from_list(fun(#{owner := Owner}) -> Owner end, Usable), Waiting}.

auction([], _Drops, _Now, _State) ->
    [];
auction(Bids, Drops, Now, State) ->
    Bidders = lists:usort([Owner || #{owner := Owner} <- Bids]),
    Decisions = football_blind_auction:resolve(
        #{lots => lots(Bids, Now, State),
          owners => #{Owner => holding(Owner, Now, State) || Owner <- Bidders},
          drops => Drops,
          max_teams => league_state:max_teams(State),
          stake_units => league_state:stake(State),
          battle_season => league_state:battle_season(Now, State)}),
    Won = lists:foldl(fun(Decision, Events) ->
                              Events ++ applied(Decision, Now, fold(Events, State))
                      end, [], Decisions),
    Decided = [Number || {_Kind, _Team, #{bid := Number}, _Detail} <- Decisions],
    Won ++ closed([Bid || #{number := Number} = Bid <- Bids,
                          not lists:member(Number, Decided)]).

lots(Bids, Now, State) ->
    [lot(Team, [Bid || #{team := Bidding} = Bid <- Bids, Bidding =:= Team], Now, State)
     || Team <- league_state:team_order(State),
        lists:any(fun(#{team := Bidding}) -> Bidding =:= Team end, Bids)].

lot(Team, Bids, Now, State) ->
    #{team => Team,
      house_owned => maps:get(owner, league_state:team(Team, State)) =:= house,
      extra_games_this_week => league_state:team_extra_games(Team, Now, State),
      bids => [#{bid => Number, owner => Owner, amount_units => Amount,
                 queued_at => Number, priority => Priority}
               || #{number := Number, owner := Owner, amount_units := Amount,
                    priority := Priority} <- Bids]}.

applied({skipped, _Team, no_longer_a_house_team}, _Now, _State) ->
    [];
applied({void, _Team, #{bid := Number}, _Why}, _Now, _State) ->
    [{order_closed, Number}];
applied({won, Team, #{bid := Number, owner := Owner, amount_units := Amount}, Room},
        Now, State) ->
    room_made(Owner, Room, Now, State)
        ++ [{team_bought, #{owner => Owner, team => Team, price_units => Amount}},
            {order_closed, Number}].

room_made(_Owner, no_drop, _Now, _State) ->
    [];
room_made(Owner, {dropping, #{number := Number, team := Team}}, Now, State) ->
    released(Owner, Team, Now, State) ++ [{order_closed, Number}].

released(Owner, Team, Now, State) ->
    case house_buys(Team, Now, State) of
        {sell, #{price_units := Price}} ->
            [{team_sold, #{owner => Owner, team => Team, price_units => Price}}];
        {refused, _Why} ->
            [{team_dropped, #{owner => Owner, team => Team}}]
    end.

add(#{number := Number} = Order, Now, State) ->
    #{team := Team} = Order,
    case {league_state:team(Team, State), league_state:rank(Team, State),
          available(Team, Now, State)} of
        {#{owner := Taken}, _Rank, _Available} when Taken =/= house ->
            {[{order_closed, Number}], []};
        {_House, {ranked, _}, _Available} ->
            {[{order_closed, Number}], []};
        {_House, unranked, {no, _Why}} ->
            {[], [Number]};
        {_House, unranked, yes} ->
            {added(Order, Now, State), []}
    end.

added(#{owner := Owner} = Order, Now, State) ->
    case length(league_state:held_by(Owner, State)) >= league_state:max_teams(State) of
        false -> added_within_the_reserve(Order, none, Now, State);
        true -> added_by_making_room(Order, Now, State)
    end.

added_by_making_room(#{number := Number, owner := Owner} = Order, Now, State) ->
    case [Drop || #{owner := Holder} = Drop <- pending(conditional_drop, State),
                  Holder =:= Owner, still_holds(Drop, State),
                  on_the_board(Drop, Now, State)] of
        [] ->
            [{order_closed, Number}];
        [#{number := DropNumber, team := DropTeam} | _Later] ->
            Released = released(Owner, DropTeam, Now, State)
                ++ [{order_closed, DropNumber}],
            Released
                ++ added_within_the_reserve(Order, DropTeam, Now, fold(Released, State))
    end.

added_within_the_reserve(#{number := Number, owner := Owner, team := Team}, Freed, Now,
                         State) ->
    #{extra_games_this_week := ExtraGames} = Holding = holding(Owner, Now, State),
    Remaining = max(0, ExtraGames - freed(Freed, Now, State)),
    Spending = Holding#{cash_out_units => 0, teams_gained => 1,
                        max_teams => league_state:max_teams(State),
                        stake_units => league_state:stake(State),
                        extra_games_this_week => Remaining,
                        battle_season => league_state:battle_season(Now, State)},
    case football_battle_reserve:headroom(Spending) of
        {fits, _Figures} -> [{team_added, #{owner => Owner, team => Team}},
                             {order_closed, Number}];
        _Short -> [{order_closed, Number}]
    end.

house_buys(Team, Now, State) ->
    football_house_buyback:decide(sale(league_state:team(Team, State), Now, State)).

freed(none, _Now, _State) -> 0;
freed(Dropped, Now, State) -> league_state:team_extra_games(Dropped, Now, State).

-spec battles(utc(), league_state:state()) -> step().
battles(Now, State) ->
    Created = league_battles:created(Now, State),
    {Created ++ league_battles:bound(Now, fold(Created, State)), []}.

one_by_one(Kind, Now, Items, State) ->
    lists:foldl(fun(Item, {Events, Rolled}) ->
                        {New, NewlyRolled} = decide(Kind, Item, Now, fold(Events, State)),
                        {Events ++ New, Rolled ++ NewlyRolled}
                end, {[], []}, Items).

closed(Orders) ->
    [{order_closed, Number} || #{number := Number} <- Orders].

numbers(Orders) ->
    [Number || #{number := Number} <- Orders].
