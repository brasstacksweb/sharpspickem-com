-module(football_battle_settlement_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_settlement_splits_the_pot_as_the_php_did_test() ->
    ?assertEqual([], golden:disagreements("decide_battle_settlement",
                                          fun port/1, fun php/2)).

port(#{<<"battle">> := Battle, <<"refund">> := Refund, <<"winnerOwnerId">> := Winner}) ->
    football_battle_settlement:decide(battle(Battle), instruction(Refund, Winner)).

battle(null) ->
    no_accepted_battle;
battle(#{<<"owner_a_id">> := OwnerA, <<"owner_b_id">> := OwnerB,
         <<"stake_cents">> := Stake, <<"house_pct">> := HousePercent}) ->
    #{owner_a => OwnerA, owner_b => OwnerB, stake_units => Stake,
      house_fee_basis_points => round(HousePercent * 100)}.

instruction(true, _Winner) -> refund_both_stakes;
instruction(false, Winner) -> {pay_winner, Winner}.

php(_In, #{<<"ok">> := false, <<"code">> := 404}) ->
    {refused, no_accepted_battle};
php(_In, #{<<"ok">> := false, <<"code">> := 400}) ->
    {refused, winner_not_in_battle};
php(_In, #{<<"mode">> := <<"refund">>, <<"stake">> := Stake}) ->
    {refund, #{stake_units => Stake}};
php(_In, #{<<"mode">> := <<"settle">>, <<"winner">> := Winner, <<"stake">> := Stake,
           <<"pot">> := Pot, <<"cut">> := Cut, <<"payout">> := Payout}) ->
    {settle, #{winner => Winner, stake_units => Stake, pot_units => Pot,
               house_fee_units => Cut, payout_units => Payout}}.
