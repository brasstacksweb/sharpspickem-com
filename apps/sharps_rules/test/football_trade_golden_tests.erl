-module(football_trade_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_allocation_books_what_the_php_booked_test() ->
    ?assertEqual([], golden:disagreements("trade_allocation", fun allocation/1,
                                          fun php_allocation/2)).

every_recorded_trade_settles_or_holds_as_the_php_did_test() ->
    ?assertEqual([], golden:disagreements("decide_trade_settlement", fun port/1,
                                          fun php/2)).

allocation(#{<<"givenBasis">> := Basis, <<"receives">> := Receives,
              <<"cash">> := Cash}) ->
    football_trade:allocation(gives(Basis), receives(Receives), Cash).

gives(null) -> gives_no_team;
gives(Basis) -> {gives, Basis}.

receives(true) -> receives_a_team;
receives(false) -> receives_no_team.

php_allocation(_In, #{<<"amount_cents">> := Proceeds,
                      <<"new_basis_cents">> := NewBasis}) ->
    maps:filter(fun(_Key, Units) -> Units =/= null end,
                #{proceeds_units => Proceeds, received_basis_units => NewBasis}).

port(#{<<"tx">> := Trade, <<"s">> := League}) ->
    only_the_figures_the_php_prints(football_trade:decide(trade(Trade), league(League))).

trade(#{<<"owner_a_id">> := OwnerA, <<"owner_b_id">> := OwnerB,
        <<"team_a_id">> := TeamFromA, <<"team_b_id">> := TeamFromB,
        <<"cash_cents">> := CashToA, <<"counterparty_confirmed">> := Confirmed}) ->
    #{owner_a => OwnerA, owner_b => OwnerB, team_from_a => team_or_none(TeamFromA),
      team_from_b => team_or_none(TeamFromB), cash_to_a_units => CashToA,
      confirmed => Confirmed}.

team_or_none(null) -> no_team;
team_or_none(Team) -> Team.

league(#{<<"teams">> := Teams, <<"owners">> := Owners, <<"max_teams">> := MaxTeams,
         <<"stake">> := Stake, <<"battles_possible">> := BattlesPossible}) ->
    #{teams => #{binary_to_integer(Id) => team(Team) || Id := Team <- Teams},
      owners => #{binary_to_integer(Id) => owner(Owner) || Id := Owner <- Owners},
      max_teams => MaxTeams, stake_units => Stake,
      battle_season => battle_season(BattlesPossible)}.

team(#{<<"owner_id">> := Owner, <<"unavailable">> := Unavailable, <<"basis">> := Basis,
       <<"extra_games">> := ExtraGames}) ->
    #{owner => Owner, tradable => not Unavailable, basis_units => Basis,
      extra_games_this_week => ExtraGames}.

owner(#{<<"funds">> := Funds, <<"escrow">> := Escrow, <<"teams_held">> := TeamsHeld,
        <<"extra_games">> := ExtraGames}) ->
    #{funds_units => Funds, escrow_units => Escrow, teams_held => TeamsHeld,
      extra_games_this_week => ExtraGames}.

battle_season(true) -> battles_being_created;
battle_season(false) -> battles_over.

only_the_figures_the_php_prints(
  {held, {Owner, {would_spend_into_the_reserve, #{reserve_units := Reserve,
                                                  teams_after := TeamsAfter}}}}) ->
    {held, {Owner, {would_spend_into_the_reserve, #{reserve_units => Reserve,
                                                    teams_after => TeamsAfter}}}};
only_the_figures_the_php_prints(Decision) ->
    Decision.

php(_In, #{<<"ok">> := true, <<"moves">> := Moves, <<"cash_cents">> := CashToA}) ->
    {settle, #{moves => [move(Move) || Move <- Moves], cash_to_a_units => CashToA}};
php(_In, #{<<"ok">> := false, <<"error">> := Error}) ->
    {held, held(Error)}.

move(#{<<"team_id">> := Team, <<"from">> := From, <<"to">> := To,
       <<"basis_cents">> := Basis, <<"amount_cents">> := Proceeds,
       <<"new_basis_cents">> := NewBasis}) ->
    #{team => Team, from => From, to => To, basis_units => Basis,
      proceeds_units => Proceeds, new_basis_units => NewBasis}.

held(<<"Both owners must confirm", _/binary>>) ->
    waiting_for_confirmation;
held(<<"Team ", _/binary>> = Error) ->
    [Team] = numbers(<<"^Team (\\d+) cannot be traded yet">>, Error),
    {not_tradable_yet, Team};
held(Error) ->
    [Owner] = numbers(<<"^Owner (\\d+) ">>, Error),
    {Owner, owners_reason(Error)}.

owners_reason(Error) ->
    case [Reason || {Pattern, Reason} <- owners_reasons(), matches(Pattern, Error)] of
        [{no_longer_owns, team}] ->
            [Team] = numbers(<<"no longer owns Team (\\d+)$">>, Error),
            {no_longer_owns, Team};
        [would_spend_into_the_reserve] ->
            [Reserve, TeamsAfter] =
                numbers(<<"below the \\$([\\d,.]+) .* for (\\d+) teams?$">>, Error),
            {would_spend_into_the_reserve, #{reserve_units => Reserve,
                                             teams_after => TeamsAfter}};
        [Reason] ->
            Reason
    end.

owners_reasons() ->
    [{<<" no longer owns ">>, {no_longer_owns, team}},
     {<<" would be over the \\d+-team maximum$">>, over_the_maximum},
     {<<" does not have enough Available Funds ">>, short_of_cash},
     {<<" cannot take on another team ">>, in_margin_call_and_gaining_a_team},
     {<<" cannot pay cash ">>, in_margin_call_and_paying_cash},
     {<<" would be left with ">>, would_spend_into_the_reserve}].

matches(Pattern, Error) ->
    re:run(Error, Pattern, [unicode]) =/= nomatch.

numbers(Pattern, Error) ->
    {match, Captured} =
        re:run(Error, Pattern, [unicode, {capture, all_but_first, binary}]),
    [units(Number) || Number <- Captured].

units(Number) ->
    binary_to_integer(binary:replace(binary:replace(Number, <<",">>, <<>>, [global]),
                                     <<".">>, <<>>)).
