-module(league_state).

-export([new/1, apply_event/2, funds/2, teams_held/1, team/2, market_value/2,
         extra_games_this_week/3, owner_ledger/1, house_ledger/1, house_balance/1]).

-export_type([state/0, event/0, ledger_row/0, game/0]).

-type owner() :: binary().

-type team() :: binary().

-type units() :: integer().

-type utc() :: {utc, integer()}.

-type game() :: #{week := pos_integer(), home_team := team(), away_team := team(),
                  kickoff := utc()}.

-type related() :: {team, team()} | {transaction, pos_integer()} | none.

-type ledger_row() :: #{
    entry := pos_integer(),
    owner := owner() | none,
    type := atom(),
    amount_units := units(),
    balance_after_units := units(),
    related := related()
}.

-type event() ::
    {league_opened, #{settings := map(), commissioner := owner(), owners := [owner()],
                      teams := [team()]}}
  | {contribution_confirmed, #{owner := owner(), units := units()}}
  | {schedule_synced, [game()]}
  | {poll_applied, #{week := pos_integer(), poll := ap | cfp,
                     ranks := #{team() => 1..25}}}
  | {draft_created, #{order := [owner()]}}
  | {draft_order_set, [owner()]}
  | draft_started
  | {team_drafted, football_draft:pick(), football_draft:stage()}
  | {draft_passed, owner(), football_draft:stage()}
  | {draft_pick_undone, football_draft:pick(), football_draft:slot()}.

-type state() :: #{
    settings := map(),
    commissioner := owner(),
    owners := #{owner() => #{funds_units := units()}},
    teams := #{team() => #{owner := owner() | house, basis_units => units()}},
    schedule := [game()],
    ranks := #{team() => 1..25},
    draft := no_draft | football_draft:draft(),
    transactions := [#{kind := draft, team := team()}],
    owner_ledger := [ledger_row()],
    house_ledger := [ledger_row()]
}.

-spec new(event()) -> state().
new({league_opened, #{settings := Settings, commissioner := Commissioner,
                      owners := Owners, teams := Teams}}) ->
    #{settings => Settings, commissioner => Commissioner,
      owners => #{Owner => #{funds_units => 0} || Owner <- Owners},
      teams => #{Team => #{owner => house} || Team <- Teams},
      schedule => [], ranks => #{}, draft => no_draft, transactions => [],
      owner_ledger => [], house_ledger => []}.

-spec apply_event(event(), state()) -> state().
apply_event({contribution_confirmed, #{owner := Owner, units := Units}}, State) ->
    owner_entry(Owner, contribution, Units, none, State);
apply_event({schedule_synced, Games}, State) ->
    State#{schedule := Games};
apply_event({poll_applied, #{ranks := Ranks}}, State) ->
    State#{ranks := Ranks};
apply_event({draft_created, #{order := Order}}, State) ->
    State#{draft := #{order => Order, stage => setup, passed => [], picks => []}};
apply_event({draft_order_set, Order}, #{draft := Draft} = State) ->
    State#{draft := Draft#{order := Order}};
apply_event(draft_started, #{draft := Draft} = State) ->
    State#{draft := Draft#{stage := {picking, {1, 1}}, passed := []}};
apply_event({team_drafted, Pick, Stage}, #{draft := #{picks := Picks} = Draft} = State) ->
    Drafted = grant(Pick, State),
    Drafted#{draft := Draft#{stage := Stage, passed := [], picks := [Pick | Picks]}};
apply_event({draft_passed, Owner, Stage}, #{draft := Draft} = State) ->
    #{passed := Passed} = Draft,
    State#{draft := Draft#{stage := Stage, passed := lists:usort([Owner | Passed])}};
apply_event({draft_pick_undone, Pick, Slot}, #{draft := Draft} = State) ->
    #{picks := [_Undone | Earlier]} = Draft,
    Released = release(Pick, State),
    Released#{draft := Draft#{stage := {picking, Slot}, passed := [], picks := Earlier}}.

grant(#{owner := Owner, team := Team, price_units := Price}, #{teams := Teams} = State) ->
    Recorded = record_transaction(draft, Team, State),
    Transaction = length(maps:get(transactions, Recorded)),
    Owned = Recorded#{teams := Teams#{Team := #{owner => Owner, basis_units => Price}}},
    paid_to_the_house(Owner, Team, Price, Transaction, Owned).

paid_to_the_house(_Owner, _Team, 0, _Transaction, State) ->
    State;
paid_to_the_house(Owner, Team, Price, Transaction, State) ->
    Paid = owner_entry(Owner, draft_purchase, -Price, {team, Team}, State),
    house_entry(Owner, draft, Price, {transaction, Transaction}, Paid).

release(#{owner := Owner, team := Team, price_units := Price},
        #{teams := Teams} = State) ->
    Transaction = last_transaction_for(Team, State),
    Released = State#{teams := Teams#{Team := #{owner => house}}},
    refunded_by_the_house(Owner, Team, Price, Transaction, Released).

refunded_by_the_house(_Owner, _Team, 0, _Transaction, State) ->
    State;
refunded_by_the_house(Owner, Team, Price, Transaction, State) ->
    Refunded = owner_entry(Owner, draft_reversal, Price, {team, Team}, State),
    house_entry(Owner, reversal, -Price, {transaction, Transaction}, Refunded).

record_transaction(Kind, Team, #{transactions := Transactions} = State) ->
    State#{transactions := Transactions ++ [#{kind => Kind, team => Team}]}.

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

-spec team(team(), state()) ->
    #{team := team(), owner := owner() | house} | not_in_the_league.
team(Team, #{teams := Teams}) ->
    case Teams of
        #{Team := #{owner := Owner}} -> #{team => Team, owner => Owner};
        #{} -> not_in_the_league
    end.

-spec market_value(team(), state()) -> units().
market_value(Team, #{ranks := Ranks}) ->
    case Ranks of
        #{Team := Rank} when is_integer(Rank) -> (27 - Rank) * 100;
        #{} -> 0
    end.

-spec extra_games_this_week(owner(), utc(), state()) -> non_neg_integer().
extra_games_this_week(Owner, Now, #{schedule := Schedule, teams := Teams}) ->
    Upcoming = [Game || #{kickoff := Kickoff} = Game <- Schedule, Kickoff > Now],
    Held = [Team || Team := #{owner := Holder} <- Teams, Holder =:= Owner],
    extra_games(Held, this_week(Upcoming)).

this_week([]) -> [];
this_week(Upcoming) ->
    Week = lists:min([Week || #{week := Week} <- Upcoming]),
    [Game || #{week := GameWeek} = Game <- Upcoming, GameWeek =:= Week].

extra_games(Held, Games) ->
    length([Game || Team <- Held,
                    [_First | BeyondTheFirst] <- [games_played_by(Team, Games)],
                    Game <- BeyondTheFirst]).

games_played_by(Team, Games) ->
    [Game || #{home_team := Home, away_team := Away} = Game <- Games,
             Team =:= Home orelse Team =:= Away].

-spec owner_ledger(state()) -> [ledger_row()].
owner_ledger(#{owner_ledger := Rows}) -> lists:reverse(Rows).

-spec house_ledger(state()) -> [ledger_row()].
house_ledger(#{house_ledger := Rows}) -> lists:reverse(Rows).

-spec house_balance(state()) -> units().
house_balance(#{house_ledger := []}) -> 0;
house_balance(#{house_ledger := [#{balance_after_units := Balance} | _Earlier]}) ->
    Balance.
