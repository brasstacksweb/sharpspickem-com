-module(league_state).

-export([new/1, apply_event/2]).

-export([funds/2, teams_held/1, held_by/2, team/2, rank/2, market_value/2, team_order/1,
         extra_games_this_week/3, team_extra_games/3, escrow/2, battle_season/2,
         season_over/2, buyback_stage/2, availability/2, games/1, game_of/2,
         final_score/3,
         pending_orders/1, pending_trades/1, battles/1, openings/1, stake/1, max_teams/1,
         owner_ledger/1, house_ledger/1, house_balance/1]).

-export_type([state/0, event/0, ledger_row/0, game/0, order/0, trade/0, battle/0,
              opening/0]).

-define(LEAD_SECONDS, 1800).

-type owner() :: binary().

-type team() :: binary().

-type units() :: integer().

-type utc() :: {utc, integer()}.

-type game() :: #{week := pos_integer(), season_type := regular | postseason,
                  home_team := team(), away_team := team(), kickoff := utc(),
                  line := football_battle_result:line(), final_at := utc(),
                  home_points := non_neg_integer(), away_points := non_neg_integer()}.

-type order() :: #{number := pos_integer(), owner := owner(), team := team(),
                   kind := bid | add | drop | sale, amount_units := units() | none,
                   conditional := boolean(), priority := non_neg_integer()}.

-type trade() :: #{number := pos_integer(), owner_a := owner(), owner_b := owner(),
                   team_from_a := team() | no_team, team_from_b := team() | no_team,
                   cash_to_a_units := units(), confirmed := boolean()}.

-type battle() :: #{number := pos_integer(), week := pos_integer(),
                    home_team := team(), away_team := team(),
                    home_owner := owner(), away_owner := owner(),
                    line := football_battle_result:line(), stake_units := units(),
                    house_fee_basis_points := non_neg_integer(),
                    status := pending | accepted | settled | refunded | rejected,
                    raise := none | {offered, owner(), units()}}.

-type related() :: {team, team()} | {transaction | trade | battle, pos_integer()} | none.

-type ledger_row() :: #{
    entry := pos_integer(),
    owner := owner() | none,
    type := atom(),
    amount_units := units(),
    balance_after_units := units(),
    related := related()
}.

-type opening() :: #{at := utc(), priced := boolean()}.

-type event() ::
    {league_opened, #{settings := map(), commissioner := owner(), owners := [owner()],
                      teams := [team()]}}
  | {contribution_confirmed, #{owner := owner(), units := units()}}
  | {schedule_synced, [game()]}
  | {poll_applied, #{week := pos_integer(), poll := ap | cfp,
                     ranks := #{team() => 1..25}}}
  | {openings_scheduled, [opening()]}
  | {buyback_boundaries, #{narrows_at := utc(), closes_at := utc()}}
  | {draft_created, #{order := [owner()]}}
  | {draft_order_set, [owner()]}
  | draft_started
  | {team_drafted, football_draft:pick(), football_draft:stage()}
  | {draft_passed, owner(), football_draft:stage()}
  | {draft_pick_undone, football_draft:pick(), football_draft:slot()}
  | {order_queued, order()}
  | {order_executed, #{owner := owner(), team := team()}}
  | {order_closed, pos_integer()}
  | {order_cancelled, pos_integer()}
  | {orders_reprioritised, [{pos_integer(), non_neg_integer()}]}
  | {team_bought, #{owner := owner(), team := team(), price_units := units()}}
  | {team_added, #{owner := owner(), team := team()}}
  | {team_dropped, #{owner := owner(), team := team()}}
  | {team_sold, #{owner := owner(), team := team(), price_units := units()}}
  | {opening_settled, opening()}
  | {trade_proposed, trade()}
  | {trade_confirmed, pos_integer()}
  | {trade_cancelled, pos_integer()}
  | {trade_settled, pos_integer(), [football_trade:move()]}
  | {battle_created, battle()}
  | {battle_dissolved, pos_integer()}
  | {battle_rejected, pos_integer()}
  | {battle_bound, pos_integer()}
  | {battle_settled, pos_integer(), #{winner := owner(), payout_units := units(),
                                       house_fee_units := units()}}
  | {battle_refunded, pos_integer()}
  | {stake_raise_offered, pos_integer(), owner(), units()}
  | {stake_raise_declined, pos_integer()}
  | {stake_raised, pos_integer(), units(), Debit :: units()}.

-type state() :: #{
    settings := map(),
    commissioner := owner(),
    owners := #{owner() => #{funds_units := units()}},
    teams := #{team() => #{owner := owner() | house, basis_units => units()}},
    team_order := [team()],
    schedule := [game()],
    ranks := #{team() => 1..25},
    openings := [opening()],
    last_priced_opening := utc() | no_opening_yet,
    draft := no_draft | football_draft:draft(),
    transactions := [#{kind := atom(), team := team()}],
    orders := #{pos_integer() => order()},
    orders_created := non_neg_integer(),
    trades := #{pos_integer() => trade()},
    trades_proposed := non_neg_integer(),
    battles := #{pos_integer() => battle()},
    battles_created := non_neg_integer(),
    owner_ledger := [ledger_row()],
    house_ledger := [ledger_row()]
}.

-spec new(event()) -> state().
new({league_opened, #{settings := Settings, commissioner := Commissioner,
                      owners := Owners, teams := Teams}}) ->
    #{settings => Settings, commissioner => Commissioner,
      owners => #{Owner => #{funds_units => 0} || Owner <- Owners},
      teams => #{Team => #{owner => house} || Team <- Teams},
      team_order => Teams, schedule => [], ranks => #{}, openings => [],
      last_priced_opening => no_opening_yet, draft => no_draft, transactions => [],
      orders => #{}, orders_created => 0, trades => #{}, trades_proposed => 0,
      battles => #{}, battles_created => 0, owner_ledger => [], house_ledger => []}.

-spec apply_event(event(), state()) -> state().
apply_event({contribution_confirmed, #{owner := Owner, units := Units}}, State) ->
    owner_entry(Owner, contribution, Units, none, State);
apply_event({schedule_synced, Games}, State) ->
    State#{schedule := Games};
apply_event({poll_applied, #{ranks := Ranks}}, State) ->
    State#{ranks := Ranks};
apply_event({openings_scheduled, Openings}, State) ->
    State#{openings := Openings};
apply_event({buyback_boundaries, Boundaries}, #{settings := Settings} = State) ->
    State#{settings := maps:merge(Settings, Boundaries)};
apply_event({draft_created, #{order := Order}}, State) ->
    State#{draft := #{order => Order, stage => setup, passed => [], picks => []}};
apply_event({draft_order_set, Order}, #{draft := Draft} = State) ->
    State#{draft := Draft#{order := Order}};
apply_event(draft_started, #{draft := Draft} = State) ->
    State#{draft := Draft#{stage := {picking, {1, 1}}, passed := []}};
apply_event({team_drafted, Pick, Stage}, #{draft := #{picks := Picks} = Draft} = State) ->
    Drafted = drafted(Pick, State),
    Drafted#{draft := Draft#{stage := Stage, passed := [], picks := [Pick | Picks]}};
apply_event({draft_passed, Owner, Stage}, #{draft := Draft} = State) ->
    #{passed := Passed} = Draft,
    State#{draft := Draft#{stage := Stage, passed := lists:usort([Owner | Passed])}};
apply_event({draft_pick_undone, Pick, Slot}, #{draft := Draft} = State) ->
    #{picks := [_Undone | Earlier]} = Draft,
    Released = undrafted(Pick, State),
    Released#{draft := Draft#{stage := {picking, Slot}, passed := [], picks := Earlier}};
apply_event({order_queued, #{number := Number} = Order}, #{orders := Orders} = State) ->
    State#{orders := Orders#{Number => Order}, orders_created := Number};
apply_event({order_executed, _Order}, #{orders_created := Created} = State) ->
    State#{orders_created := Created + 1};
apply_event({order_closed, Number}, #{orders := Orders} = State) ->
    State#{orders := maps:remove(Number, Orders)};
apply_event({order_cancelled, Number}, #{orders := Orders} = State) ->
    State#{orders := maps:remove(Number, Orders)};
apply_event({orders_reprioritised, Priorities}, #{orders := Orders} = State) ->
    State#{orders := lists:foldl(fun reprioritised/2, Orders, Priorities)};
apply_event({team_bought, #{owner := Owner, team := Team, price_units := Price}},
            State) ->
    {Transaction, Recorded} = transaction(house_purchase, Team, State),
    Owned = owned(Team, Owner, Price, Recorded),
    Paid = owner_entry(Owner, house_purchase, -Price, {team, Team}, Owned),
    house_entry(Owner, house_purchase, Price, {transaction, Transaction}, Paid);
apply_event({team_added, #{owner := Owner, team := Team}}, State) ->
    {_Transaction, Recorded} = transaction(add, Team, State),
    owned(Team, Owner, 0, Recorded);
apply_event({team_dropped, #{team := Team}}, State) ->
    {_Transaction, Recorded} = transaction(drop, Team, State),
    to_the_house(Team, Recorded);
apply_event({team_sold, #{owner := Owner, team := Team, price_units := Price}}, State) ->
    {Transaction, Recorded} = transaction(house_sale, Team, State),
    Sold = to_the_house(Team, Recorded),
    Paid = owner_entry(Owner, house_sale, Price, {team, Team}, Sold),
    house_entry(Owner, house_sale, -Price, {transaction, Transaction}, Paid);
apply_event({opening_settled, #{at := At, priced := Priced} = Opening},
            #{openings := Openings} = State) ->
    State#{openings := Openings -- [Opening],
           last_priced_opening := case Priced of
                                      true -> At;
                                      false -> maps:get(last_priced_opening, State)
                                  end};
apply_event({trade_proposed, #{number := Number} = Trade}, #{trades := Trades} = State) ->
    State#{trades := Trades#{Number => Trade}, trades_proposed := Number};
apply_event({trade_confirmed, Number}, #{trades := Trades} = State) ->
    #{Number := Trade} = Trades,
    State#{trades := Trades#{Number := Trade#{confirmed := true}}};
apply_event({trade_cancelled, Number}, #{trades := Trades} = State) ->
    State#{trades := maps:remove(Number, Trades)};
apply_event({trade_settled, Number, Moves}, #{trades := Trades} = State) ->
    #{Number := Trade} = Trades,
    Moved = lists:foldl(fun moved/2, State, Moves),
    paid_between_owners(Number, Trade, Moved#{trades := maps:remove(Number, Trades)});
apply_event({battle_created, #{number := Number} = Battle},
            #{battles := Battles} = State) ->
    State#{battles := Battles#{Number => Battle}, battles_created := Number};
apply_event({battle_dissolved, Number}, #{battles := Battles} = State) ->
    State#{battles := maps:remove(Number, Battles)};
apply_event({battle_rejected, Number}, State) ->
    with_status(Number, rejected, State);
apply_event({battle_bound, Number}, #{battles := Battles} = State) ->
    #{Number := #{stake_units := Stake}} = Battles,
    with_status(Number, accepted, each_side(Number, battle_stake, -Stake, State));
apply_event({battle_settled, Number, #{winner := Winner, payout_units := Payout,
                                       house_fee_units := Fee}},
            #{battles := Battles} = State) ->
    Paid = owner_entry(Winner, battle_winnings, Payout, {battle, Number}, State),
    Cut = house_fee(Number, Fee, Paid),
    with_status(Number, settled, Cut#{battles := Battles});
apply_event({battle_refunded, Number}, #{battles := Battles} = State) ->
    #{Number := #{stake_units := Stake}} = Battles,
    with_status(Number, refunded, each_side(Number, battle_refund, Stake, State));
apply_event({stake_raise_offered, Number, Owner, Stake}, #{battles := Battles} = State) ->
    #{Number := Battle} = Battles,
    State#{battles := Battles#{Number := Battle#{raise := {offered, Owner, Stake}}}};
apply_event({stake_raise_declined, Number}, #{battles := Battles} = State) ->
    #{Number := Battle} = Battles,
    State#{battles := Battles#{Number := Battle#{raise := none}}};
apply_event({stake_raised, Number, Stake, Debit}, #{battles := Battles} = State) ->
    #{Number := Battle} = Battles,
    Raised = raised_stakes(Number, Debit, State),
    Raised#{battles := Battles#{Number := Battle#{stake_units := Stake, raise := none}}}.

reprioritised({Number, Priority}, Orders) ->
    #{Number := Order} = Orders,
    Orders#{Number := Order#{priority := Priority}}.

each_side(Number, Type, Amount, #{battles := Battles} = State) ->
    #{Number := #{home_owner := Home, away_owner := Away}} = Battles,
    WithHome = owner_entry(Home, Type, Amount, {battle, Number}, State),
    owner_entry(Away, Type, Amount, {battle, Number}, WithHome).

with_status(Number, Status, #{battles := Battles} = State) ->
    #{Number := Battle} = Battles,
    State#{battles := Battles#{Number := Battle#{status := Status}}}.

drafted(#{owner := Owner, team := Team, price_units := Price}, State) ->
    {Transaction, Recorded} = transaction(draft, Team, State),
    Owned = owned(Team, Owner, Price, Recorded),
    paid_to_the_house(Owner, Team, Price, Transaction, Owned).

paid_to_the_house(_Owner, _Team, 0, _Transaction, State) ->
    State;
paid_to_the_house(Owner, Team, Price, Transaction, State) ->
    Paid = owner_entry(Owner, draft_purchase, -Price, {team, Team}, State),
    house_entry(Owner, draft, Price, {transaction, Transaction}, Paid).

undrafted(#{owner := Owner, team := Team, price_units := Price}, State) ->
    Transaction = last_transaction_for(Team, State),
    refunded_by_the_house(Owner, Team, Price, Transaction, to_the_house(Team, State)).

refunded_by_the_house(_Owner, _Team, 0, _Transaction, State) ->
    State;
refunded_by_the_house(Owner, Team, Price, Transaction, State) ->
    Refunded = owner_entry(Owner, draft_reversal, Price, {team, Team}, State),
    house_entry(Owner, reversal, -Price, {transaction, Transaction}, Refunded).

moved(#{team := Team, to := To, new_basis_units := NewBasis}, State) ->
    {_Transaction, Recorded} = transaction(trade, Team, State),
    owned(Team, To, NewBasis, Recorded).

paid_between_owners(_Number, #{cash_to_a_units := 0}, State) ->
    State;
paid_between_owners(Number, #{owner_a := OwnerA, owner_b := OwnerB,
                              cash_to_a_units := Cash}, State) ->
    {Payer, Payee} = case Cash > 0 of
                         true -> {OwnerB, OwnerA};
                         false -> {OwnerA, OwnerB}
                     end,
    Paid = owner_entry(Payer, trade_payment, -abs(Cash), {trade, Number}, State),
    owner_entry(Payee, trade_receipt, abs(Cash), {trade, Number}, Paid).

house_fee(_Number, 0, State) -> State;
house_fee(Number, Fee, State) -> house_entry(none, battle, Fee, {battle, Number}, State).

raised_stakes(_Number, 0, State) -> State;
raised_stakes(Number, Debit, State) -> each_side(Number, battle_stake, -Debit, State).

owned(Team, Owner, Basis, #{teams := Teams} = State) ->
    State#{teams := Teams#{Team := #{owner => Owner, basis_units => Basis}}}.

to_the_house(Team, #{teams := Teams} = State) ->
    State#{teams := Teams#{Team := #{owner => house}}}.

transaction(Kind, Team, #{transactions := Transactions} = State) ->
    {length(Transactions) + 1,
     State#{transactions := Transactions ++ [#{kind => Kind, team => Team}]}}.

last_transaction_for(Team, #{transactions := Transactions}) ->
    lists:max([Number || {Number, #{team := Teamed}} <- lists:enumerate(Transactions),
                         Teamed =:= Team]).

owner_entry(Owner, Type, Amount, Related,
            #{owners := Owners, owner_ledger := Rows} = State) ->
    #{Owner := #{funds_units := Funds} = Account} = Owners,
    After = Funds + Amount,
    State#{owners := Owners#{Owner := Account#{funds_units := After}},
           owner_ledger := [row(length(Rows) + 1, Owner, Type, Amount, After, Related)
                            | Rows]}.

house_entry(Owner, Type, Amount, Related, #{house_ledger := Rows} = State) ->
    After = house_balance(State) + Amount,
    State#{house_ledger := [row(length(Rows) + 1, Owner, Type, Amount, After, Related)
                            | Rows]}.

row(Entry, Owner, Type, Amount, After, Related) ->
    #{entry => Entry, owner => Owner, type => Type, amount_units => Amount,
      balance_after_units => After, related => Related}.

-spec funds(owner(), state()) -> units().
funds(Owner, #{owners := Owners}) ->
    #{Owner := #{funds_units := Funds}} = Owners,
    Funds.

-spec teams_held(state()) -> #{owner() => non_neg_integer()}.
teams_held(#{teams := Teams, owners := Owners}) ->
    Held = [Owner || _Team := #{owner := Owner} <- Teams, Owner =/= house],
    #{Owner => length([Holder || Holder <- Held, Holder =:= Owner])
      || Owner := _Account <- Owners}.

-spec held_by(owner(), state()) -> [team()].
held_by(Owner, #{teams := Teams}) ->
    [Team || Team := #{owner := Holder} <- Teams, Holder =:= Owner].

-spec team(team(), state()) ->
    #{team := team(), owner := owner() | house, basis_units => units()}
  | not_in_the_league.
team(Team, #{teams := Teams}) ->
    case Teams of
        #{Team := Held} -> Held#{team => Team};
        #{} -> not_in_the_league
    end.

-spec rank(team(), state()) -> football_house_buyback:rank().
rank(Team, #{ranks := Ranks}) ->
    case Ranks of
        #{Team := Rank} -> {ranked, Rank};
        #{} -> unranked
    end.

-spec market_value(team(), state()) -> units().
market_value(Team, #{ranks := Ranks}) ->
    case Ranks of
        #{Team := Rank} when is_integer(Rank) -> (27 - Rank) * 100;
        #{} -> 0
    end.

-spec team_order(state()) -> [team()].
team_order(#{team_order := Teams}) -> Teams.

-spec extra_games_this_week(owner(), utc(), state()) -> non_neg_integer().
extra_games_this_week(Owner, Now, State) ->
    Games = this_week(Now, State),
    length([Game || Team <- held_by(Owner, State),
                    [_First | BeyondTheFirst] <- [games_played_by(Team, Games)],
                    Game <- BeyondTheFirst]).

-spec team_extra_games(team(), utc(), state()) -> non_neg_integer().
team_extra_games(Team, Now, State) ->
    max(0, length(games_played_by(Team, this_week(Now, State))) - 1).

this_week(Now, #{schedule := Schedule}) ->
    Upcoming = [Game || #{season_type := regular, kickoff := Kickoff} = Game <- Schedule,
                        Kickoff > Now],
    case Upcoming of
        [] -> [];
        _Games -> Week = lists:min([Week || #{week := Week} <- Upcoming]),
                  [Game || #{week := GameWeek} = Game <- Upcoming, GameWeek =:= Week]
    end.

games_played_by(Team, Games) ->
    [Game || #{home_team := Home, away_team := Away} = Game <- Games,
             Team =:= Home orelse Team =:= Away].

-spec escrow(owner(), state()) -> units().
escrow(Owner, #{battles := Battles} = State) ->
    Accepted = [Number || Number := #{status := accepted, home_owner := Home,
                                      away_owner := Away} <- Battles,
                          Owner =:= Home orelse Owner =:= Away],
    min(length(Accepted), length(held_by(Owner, State))) * stake(State).

-spec battle_season(utc(), state()) -> football_battle_reserve:battle_season().
battle_season(Now, #{schedule := Schedule}) ->
    Regular = [Game || #{season_type := regular} = Game <- Schedule],
    case Regular =/= [] andalso all_finished(Regular, Now) of
        true -> battles_over;
        false -> battles_being_created
    end.

all_finished(Games, Now) ->
    lists:all(fun(Game) -> finished(Game, Now) end, Games).

-spec season_over(utc(), state()) -> boolean().
season_over(Now, #{schedule := Schedule} = State) ->
    Postseason = [Game || #{season_type := postseason} = Game <- Schedule],
    battle_season(Now, State) =:= battles_over
        andalso Postseason =/= []
        andalso all_finished(Postseason, Now).

finished(#{final_at := FinalAt}, Now) -> FinalAt =< Now.

-spec buyback_stage(utc(), state()) -> football_house_buyback:stage().
buyback_stage(Now, #{settings := #{closes_at := ClosesAt}}) when Now >= ClosesAt ->
    buys_nothing;
buyback_stage(Now, #{settings := #{narrows_at := NarrowsAt}}) when Now >= NarrowsAt ->
    buys_the_top_12;
buyback_stage(_Now, _State) ->
    buys_the_top_25.

-spec availability(utc(), state()) ->
    #{team() => #{available := football_availability:answer(),
                  tradable := football_availability:answer()}}.
availability(Now, #{team_order := Teams, battles := Battles,
                    last_priced_opening := OpenedAt} = State) ->
    InBattle = lists:append([[Home, Away]
                             || _Number := #{status := accepted, home_team := Home,
                                             away_team := Away} <- Battles]),
    football_availability:decide(
        #{teams => [#{team => Team, live_battle => lists:member(Team, InBattle)}
                    || Team <- Teams],
          games => [availability_game(Game, Now) || Game <- games(State)],
          opened_at => OpenedAt,
          now => Now,
          kickoff_lead_seconds => ?LEAD_SECONDS}).

availability_game(#{final_at := FinalAt} = Game, Now) ->
    (maps:with([home_team, away_team, kickoff, week, season_type], Game))#{
        completed => FinalAt =< Now}.

-spec games(state()) -> [game()].
games(#{schedule := Schedule}) -> Schedule.

-spec game_of(battle(), state()) -> game() | not_scheduled.
game_of(#{week := Week, home_team := Home, away_team := Away}, State) ->
    case [Game || #{season_type := regular, week := GameWeek, home_team := GameHome,
                    away_team := GameAway} = Game <- games(State),
                  GameWeek =:= Week, GameHome =:= Home, GameAway =:= Away] of
        [Game | _Again] -> Game;
        [] -> not_scheduled
    end.

-spec final_score(battle(), utc(), state()) -> {final, game()} | not_final.
final_score(Battle, Now, State) ->
    case game_of(Battle, State) of
        #{final_at := FinalAt} = Game when FinalAt =< Now -> {final, Game};
        _NotYet -> not_final
    end.

-spec pending_orders(state()) -> [order()].
pending_orders(#{orders := Orders}) ->
    [Order || _Number := Order <- maps:iterator(Orders, ordered)].

-spec pending_trades(state()) -> [trade()].
pending_trades(#{trades := Trades}) ->
    [Trade || _Number := Trade <- maps:iterator(Trades, ordered)].

-spec battles(state()) -> [battle()].
battles(#{battles := Battles}) ->
    [Battle || _Number := Battle <- maps:iterator(Battles, ordered)].

-spec openings(state()) -> [opening()].
openings(#{openings := Openings}) -> Openings.

-spec stake(state()) -> units().
stake(#{settings := #{stake_units := Stake}}) -> Stake.

-spec max_teams(state()) -> pos_integer().
max_teams(#{settings := #{max_teams := MaxTeams}}) -> MaxTeams.

-spec owner_ledger(state()) -> [ledger_row()].
owner_ledger(#{owner_ledger := Rows}) -> lists:reverse(Rows).

-spec house_ledger(state()) -> [ledger_row()].
house_ledger(#{house_ledger := Rows}) -> lists:reverse(Rows).

-spec house_balance(state()) -> units().
house_balance(#{house_ledger := []}) -> 0;
house_balance(#{house_ledger := [#{balance_after_units := Balance} | _Earlier]}) ->
    Balance.
