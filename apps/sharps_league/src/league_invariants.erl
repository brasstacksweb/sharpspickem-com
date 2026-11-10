-module(league_invariants).

-export([broken/2]).

-export_type([violation/0]).

-type owner() :: binary().

-type units() :: integer().

-type utc() :: {utc, integer()}.

-type book() :: {owner, owner()} | house.

-type violation() ::
    {house_negative, units()}
  | {funds_off_the_ledger, owner(), #{funds_units := units(), ledger_units := units()}}
  | {chain_broken, book(), Entry :: pos_integer()}
  | {unclassified_ledger_type, owner | house, atom()}
  | {money_created_or_destroyed, #{internal_units := units(), expected_units := units()}}
  | {conservation_broken, #{held_units := units(), external_units := units()}}
  | {over_max_teams, owner(), non_neg_integer()}
  | {basis_mismatch, Team :: binary()}
  | {stakes_not_released, Battle :: pos_integer()}
  | {under_the_reserve, owner(), #{short_units := units(), allowed_units := units()}}
  | {prize_pool_not_distributed, #{pool_units := units(), paid_units := units()}}.

-define(EXTERNAL_TO_OWNERS, [contribution, commissioner_adjustment, reversal,
                             season_settlement]).

-define(INTERNAL_TO_OWNERS, [draft_purchase, draft_reversal, house_purchase, house_sale,
                             trade_payment, trade_receipt, battle_stake, battle_winnings,
                             battle_refund, payout]).

-define(INTERNAL_TO_THE_HOUSE, [draft, house_purchase, house_sale, battle, reversal,
                                payout]).

-define(SET_BY_THE_COMMISSIONER, [commissioner_adjustment, reversal]).

-spec broken(utc(), league_state:state()) -> [violation()].
broken(Now, State) ->
    Books = books(State),
    lists:append([house_not_negative(State),
                  funds_match_the_ledger(Books, State),
                  chains_unbroken(Books),
                  types_classified(Books),
                  money_conserved(Books, State),
                  within_max_teams(State),
                  bases_match_ownership(State),
                  stakes_released(Books, State),
                  reserves_kept(Now, Books, State),
                  prize_pool_distributed(Books, State)]).

books(#{owners := Owners} = State) ->
    OwnerRows = league_state:owner_ledger(State),
    ByOwner = maps:groups_from_list(fun(#{owner := Owner}) -> Owner end, OwnerRows),
    #{owner_rows => OwnerRows,
      house_rows => league_state:house_ledger(State),
      by_owner => maps:merge(#{Owner => [] || Owner := _Account <- Owners}, ByOwner),
      paid_by_battle => maps:groups_from_list(fun battle_paid/1, fun type/1,
                                              [Row || #{related := {battle, _}} = Row
                                                          <- OwnerRows]),
      winners => #{Number => Winner
                   || #{type := battle_winnings, owner := Winner,
                        related := {battle, Number}} <- OwnerRows}}.

battle_paid(#{related := {battle, Number}}) -> Number.

type(#{type := Type}) -> Type.

house_not_negative(State) ->
    case league_state:house_balance(State) of
        Negative when Negative < 0 -> [{house_negative, Negative}];
        _Balance -> []
    end.

funds_match_the_ledger(#{by_owner := ByOwner}, #{owners := Owners}) ->
    [{funds_off_the_ledger, Owner, #{funds_units => Funds, ledger_units => Tip}}
     || Owner := #{funds_units := Funds} <- maps:iterator(Owners, ordered),
        Tip <- [ledger_tip(maps:get(Owner, ByOwner))],
        Funds =/= Tip].

ledger_tip([]) -> 0;
ledger_tip(Rows) -> maps:get(balance_after_units, lists:last(Rows)).

chains_unbroken(#{owner_rows := OwnerRows, house_rows := HouseRows, by_owner := ByOwner}) ->
    lists:append([chain({owner, Owner}, Rows)
                  || Owner := Rows <- maps:iterator(ByOwner, ordered)])
        ++ chain(house, HouseRows)
        ++ numbered(owner_book, OwnerRows) ++ numbered(house, HouseRows).

chain(Book, Rows) ->
    {Broken, _Tip} = lists:foldl(fun(Row, SoFar) -> link(Book, Row, SoFar) end,
                                 {[], 0}, Rows),
    Broken.

link(Book, #{entry := Entry, amount_units := Amount, balance_after_units := After},
     {Broken, Before}) ->
    case Before + Amount of
        After -> {Broken, After};
        _Elsewhere -> {Broken ++ [{chain_broken, Book, Entry}], After}
    end.

numbered(Book, Rows) ->
    [{chain_broken, as_a_book(Book, Row), Entry}
     || {Expected, #{entry := Entry} = Row} <- lists:enumerate(Rows), Entry =/= Expected].

as_a_book(owner_book, #{owner := Owner}) -> {owner, Owner};
as_a_book(house, _Row) -> house.

types_classified(#{owner_rows := OwnerRows, house_rows := HouseRows}) ->
    lists:usort(
      [{unclassified_ledger_type, owner, Type}
       || #{type := Type} <- OwnerRows,
          not lists:member(Type, ?EXTERNAL_TO_OWNERS ++ ?INTERNAL_TO_OWNERS)]
      ++ [{unclassified_ledger_type, house, Type}
          || #{type := Type} <- HouseRows, not lists:member(Type, ?INTERNAL_TO_THE_HOUSE)]).

money_conserved(#{owner_rows := OwnerRows, house_rows := HouseRows},
                #{owners := Owners} = State) ->
    External = sum([Row || #{type := Type} = Row <- OwnerRows,
                           lists:member(Type, ?EXTERNAL_TO_OWNERS)]),
    Internal = sum([Row || #{type := Type} = Row <- OwnerRows,
                           not lists:member(Type, ?EXTERNAL_TO_OWNERS)])
        + sum(HouseRows),
    Escrow = lists:sum([2 * Stake || #{status := accepted, stake_units := Stake}
                                         <- league_state:battles(State)]),
    Held = lists:sum([Funds || _Owner := #{funds_units := Funds} <- Owners])
        + league_state:house_balance(State) + Escrow,
    [{money_created_or_destroyed, #{internal_units => Internal,
                                    expected_units => -Escrow}}
     || Internal =/= -Escrow]
        ++ [{conservation_broken, #{held_units => Held, external_units => External}}
            || Held =/= External].

sum(Rows) ->
    lists:sum([Amount || #{amount_units := Amount} <- Rows]).

within_max_teams(State) ->
    MaxTeams = league_state:max_teams(State),
    [{over_max_teams, Owner, Held}
     || Owner := Held <- maps:iterator(league_state:teams_held(State), ordered),
        Held > MaxTeams].

bases_match_ownership(#{teams := Teams}) ->
    [{basis_mismatch, Team}
     || Team := Held <- maps:iterator(Teams, ordered),
        is_map_key(basis_units, Held) =:= (maps:get(owner, Held) =:= house)].

stakes_released(#{paid_by_battle := PaidByBattle}, State) ->
    [{stakes_not_released, Number}
     || #{number := Number, status := Status} <- league_state:battles(State),
        not released(Status, maps:get(Number, PaidByBattle, []))].

released(settled, Paid) -> count(battle_winnings, Paid) =:= 1;
released(refunded, Paid) -> count(battle_refund, Paid) =:= 2;
released(_PendingAcceptedOrRejected, _Paid) -> true.

count(Type, Types) ->
    length([Same || Same <- Types, Same =:= Type]).

reserves_kept(Now, Books, #{owners := Owners} = State) ->
    case league_state:battle_season(Now, State) of
        battles_being_created ->
            [Violation || Owner := _Account <- maps:iterator(Owners, ordered),
                          Violation <- reserve_kept(Owner, Books, State)];
        battles_over ->
            []
    end.

reserve_kept(Owner, #{by_owner := ByOwner, winners := Winners}, State) ->
    Battles = [Battle || #{home_owner := Home, away_owner := Away} = Battle
                             <- league_state:battles(State),
                         Owner =:= Home orelse Owner =:= Away],
    Escrow = lists:sum([Stake || #{status := accepted, stake_units := Stake} <- Battles]),
    Base = length(league_state:held_by(Owner, State)) * league_state:stake(State),
    Short = Base - (league_state:funds(Owner, State) + Escrow),
    Allowed = stakes_lost(Owner, Battles, Winners)
        + set_by_the_commissioner(maps:get(Owner, ByOwner)),
    [{under_the_reserve, Owner, #{short_units => Short, allowed_units => Allowed}}
     || Short > Allowed].

stakes_lost(Owner, Battles, Winners) ->
    lists:sum([Stake || #{number := Number, status := settled, stake_units := Stake}
                            <- Battles,
                        maps:get(Number, Winners, none) =/= Owner]).

set_by_the_commissioner(Rows) ->
    lists:sum([-Amount || #{type := Type, amount_units := Amount} <- Rows, Amount < 0,
                          lists:member(Type, ?SET_BY_THE_COMMISSIONER)]).

prize_pool_distributed(#{house_rows := HouseRows}, State) ->
    Slots = lists:sum([Games || {_Round, _Share, Games}
                                    <- football_playoff_payout:schedule()]),
    case {league_state:prize_pool(State), length(league_state:playoff_slots(State))} of
        {Pool, Slots} when is_integer(Pool) ->
            Paid = -sum([Row || #{type := payout} = Row <- HouseRows]),
            [{prize_pool_not_distributed, #{pool_units => Pool, paid_units => Paid}}
             || Paid =/= Pool];
        {_PoolOrNot, _Recorded} ->
            []
    end.
