-module(football_trade).

-rule("§9").

-export([allocation/3, decide/2]).

-export_type([trade/0, league/0, move/0, decision/0]).

-type units() :: integer().

-type owner() :: term().

-type team() :: term().

-type trade() :: #{
    owner_a := owner(),
    owner_b := owner(),
    team_from_a := team() | no_team,
    team_from_b := team() | no_team,
    cash_to_a_units := units(),
    confirmed := boolean()
}.

-type team_state() :: #{
    owner := owner(),
    tradable := boolean(),
    basis_units := units(),
    extra_games_this_week := non_neg_integer()
}.

-type owner_state() :: #{
    funds_units := units(),
    escrow_units := units(),
    teams_held := non_neg_integer(),
    extra_games_this_week := non_neg_integer()
}.

-type league() :: #{
    teams := #{team() => team_state()},
    owners := #{owner() => owner_state()},
    max_teams := non_neg_integer(),
    stake_units := units(),
    battle_season := football_battle_reserve:battle_season()
}.

-type move() :: #{
    team := team(),
    from := owner(),
    to := owner(),
    basis_units := units(),
    proceeds_units := units(),
    new_basis_units := units()
}.

-type decision() ::
    {settle, #{moves := [move()], cash_to_a_units := units()}}
  | {held, term()}
  | {refused, moves_no_team | {paid_with_no_team_behind_it, owner()}}.

-type allocation() :: #{proceeds_units => units(), received_basis_units => units()}.

-spec allocation({gives, units()} | gives_no_team, receives_a_team | receives_no_team,
                 units()) -> allocation().
allocation({gives, _Basis}, receives_no_team, CashIn) ->
    #{proceeds_units => CashIn};
allocation(gives_no_team, receives_a_team, CashIn) ->
    #{received_basis_units => -CashIn};
allocation({gives, Basis}, receives_a_team, CashIn) ->
    RolledBasis = max(0, Basis - CashIn),
    #{proceeds_units => RolledBasis + CashIn, received_basis_units => RolledBasis}.

-spec decide(trade(), league()) -> decision().
decide(#{cash_to_a_units := Cash} = Trade, #{teams := Teams} = League) ->
    Sides = sides(Trade),
    maybe
        ok ?= well_formed(Sides),
        ok ?= confirmed(Trade),
        ok ?= first_failure([still_owns(Side, Teams) || Side <- Sides]),
        ok ?= first_failure([tradable(Side, Teams) || Side <- Sides]),
        ok ?= first_failure([affordable(Side, League) || Side <- Sides]),
        {settle, #{moves => moves(Sides, Teams), cash_to_a_units => Cash}}
    end.

sides(#{owner_a := OwnerA, owner_b := OwnerB, team_from_a := TeamFromA,
        team_from_b := TeamFromB, cash_to_a_units := Cash}) ->
    [#{owner => OwnerA, gives => TeamFromA, receives => TeamFromB,
       cash_in_units => Cash},
     #{owner => OwnerB, gives => TeamFromB, receives => TeamFromA,
       cash_in_units => -Cash}].

well_formed([#{gives := no_team, receives := no_team} | _]) ->
    {refused, moves_no_team};
well_formed(Sides) ->
    first_failure([cash_backed(Side) || Side <- Sides]).

cash_backed(#{owner := Owner, gives := no_team, cash_in_units := Cash}) when Cash > 0 ->
    {refused, {paid_with_no_team_behind_it, Owner}};
cash_backed(_Side) ->
    ok.

confirmed(#{confirmed := true}) -> ok;
confirmed(#{confirmed := false}) -> {held, waiting_for_confirmation}.

still_owns(#{gives := no_team}, _Teams) ->
    ok;
still_owns(#{owner := Owner, gives := Team}, Teams) ->
    case Teams of
        #{Team := #{owner := Owner}} -> ok;
        #{} -> {held, {Owner, {no_longer_owns, Team}}}
    end.

tradable(#{gives := no_team}, _Teams) ->
    ok;
tradable(#{gives := Team}, Teams) ->
    case Teams of
        #{Team := #{tradable := true}} -> ok;
        #{} -> {held, {not_tradable_yet, Team}}
    end.

affordable(#{owner := Owner, cash_in_units := CashIn} = Side,
           #{owners := Owners, teams := Teams, max_teams := MaxTeams} = League) ->
    #{Owner := #{funds_units := Funds} = Before} = Owners,
    #{teams_held := TeamsAfter} = After = after_the_trade(Side, Before, Teams),
    CashOut = max(0, -CashIn),
    Standing = standing(Before, League),
    Verdict = maybe
        ok ?= within_the_maximum(TeamsAfter, MaxTeams),
        ok ?= covers_the_cash(CashOut, Funds),
        ok ?= margin_call_allows(Standing, teams_gained(Side), CashOut),
        ok ?= reserve_allows(Standing, headroom(After, CashOut, League))
    end,
    on_behalf_of(Owner, Verdict).

after_the_trade(#{gives := Given, receives := Received} = Side,
                #{teams_held := TeamsHeld, extra_games_this_week := ExtraGames} = Before,
                Teams) ->
    Arriving = extra_games(Received, Teams),
    Leaving = extra_games(Given, Teams),
    Before#{teams_held := TeamsHeld + teams_gained(Side),
            extra_games_this_week := max(0, ExtraGames + Arriving - Leaving)}.

standing(Before, League) ->
    {Standing, _Figures} =
        football_battle_reserve:margin_call(reserve_basis(Before, League)),
    Standing.

headroom(After, CashOut, #{max_teams := MaxTeams} = League) ->
    football_battle_reserve:headroom((reserve_basis(After, League))#{
        teams_gained => 0, max_teams => MaxTeams, cash_out_units => CashOut}).

teams_gained(#{gives := Given, receives := Received}) ->
    count_team(Received) - count_team(Given).

count_team(no_team) -> 0;
count_team(_Team) -> 1.

within_the_maximum(TeamsAfter, MaxTeams) when TeamsAfter > MaxTeams ->
    {held, over_the_maximum};
within_the_maximum(_TeamsAfter, _MaxTeams) ->
    ok.

covers_the_cash(CashOut, Funds) when CashOut > Funds ->
    {held, short_of_cash};
covers_the_cash(_CashOut, _Funds) ->
    ok.

margin_call_allows(in_good_standing, _TeamsGained, _CashOut) ->
    ok;
margin_call_allows(in_margin_call, 1, _CashOut) ->
    {held, in_margin_call_and_gaining_a_team};
margin_call_allows(in_margin_call, _TeamsGained, CashOut) when CashOut > 0 ->
    {held, in_margin_call_and_paying_cash};
margin_call_allows(in_margin_call, _TeamsGained, 0) ->
    ok.

reserve_allows(in_margin_call, _Headroom) ->
    ok;
reserve_allows(in_good_standing, {fits, _Figures}) ->
    ok;
reserve_allows(in_good_standing, {spends_into_the_reserve, Figures}) ->
    {held, {would_spend_into_the_reserve, Figures}}.

extra_games(no_team, _Teams) -> 0;
extra_games(Team, Teams) ->
    #{Team := #{extra_games_this_week := ExtraGames}} = Teams,
    ExtraGames.

reserve_basis(#{funds_units := Funds, escrow_units := Escrow, teams_held := TeamsHeld,
                extra_games_this_week := ExtraGames},
              #{stake_units := Stake, battle_season := BattleSeason}) ->
    #{funds_units => Funds, escrow_units => Escrow, teams_held => TeamsHeld,
      extra_games_this_week => ExtraGames, stake_units => Stake,
      battle_season => BattleSeason}.

on_behalf_of(_Owner, ok) -> ok;
on_behalf_of(Owner, {held, Reason}) -> {held, {Owner, Reason}}.

first_failure(Checks) ->
    case [Check || Check <- Checks, Check =/= ok] of
        [] -> ok;
        [FirstFailure | _Later] -> FirstFailure
    end.

moves([SideA, SideB], Teams) ->
    move(SideA, SideB, Teams) ++ move(SideB, SideA, Teams).

move(#{gives := no_team}, _Receiver, _Teams) ->
    [];
move(#{owner := From, gives := Team} = Giver, #{owner := To} = Receiver, Teams) ->
    #{proceeds_units := Proceeds} = allocation_for(Giver, Teams),
    #{received_basis_units := NewBasis} = allocation_for(Receiver, Teams),
    [#{team => Team, from => From, to => To, basis_units => basis(Team, Teams),
       proceeds_units => Proceeds, new_basis_units => NewBasis}].

allocation_for(#{gives := Given, receives := Received, cash_in_units := CashIn}, Teams) ->
    allocation(gives(Given, Teams), receives(Received), CashIn).

gives(no_team, _Teams) -> gives_no_team;
gives(Team, Teams) -> {gives, basis(Team, Teams)}.

receives(no_team) -> receives_no_team;
receives(_Team) -> receives_a_team.

basis(Team, Teams) ->
    #{Team := #{basis_units := Basis}} = Teams,
    Basis.
