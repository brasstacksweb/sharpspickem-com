-module(football_battle_settlement_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OWNER_A, 7).
-define(OWNER_B, 12).
-define(SOMEONE_ELSE, 31).

the_rulebook_example_test_() ->
    {settle, Settlement} = pay(?OWNER_A, battle(500, 1000)),
    [
        {"§11: $5 each makes a $10 pot",
         ?_assertEqual(1000, maps:get(pot_units, Settlement))},
        {"§11: $1.00 to the House Account",
         ?_assertEqual(100, maps:get(house_fee_units, Settlement))},
        {"§11: $9.00 to the winning owner",
         ?_assertEqual(900, maps:get(payout_units, Settlement))}
    ].

either_owner_can_win_test_() ->
    [
        {"owner A wins",
         ?_assertMatch({settle, #{winner := ?OWNER_A}},
                       pay(?OWNER_A, battle(500, 1000)))},
        {"owner B wins; catches checking only owner A",
         ?_assertMatch({settle, #{winner := ?OWNER_B}},
                       pay(?OWNER_B, battle(500, 1000)))}
    ].

a_refund_takes_no_house_fee_test() ->
    ?assertEqual({refund, #{stake_units => 500}},
                 football_battle_settlement:decide(battle(500, 1000),
                                                   refund_both_stakes)).

refusals_test_() ->
    [
        {"a winner outside the Battle is refused, not paid",
         ?_assertEqual({refused, winner_not_in_battle},
                       pay(?SOMEONE_ELSE, battle(500, 1000)))},
        {"no accepted Battle is refused before anything else",
         ?_assertEqual({refused, no_accepted_battle},
                       football_battle_settlement:decide(no_accepted_battle,
                                                         refund_both_stakes))}
    ].

the_house_fee_rounds_half_up_test_() ->
    [
        {"2.5% of a $10.20 pot is 25.5 units, rounded up to 26; catches truncating",
         ?_assertMatch({settle, #{house_fee_units := 26, payout_units := 994}},
                       pay(?OWNER_A, battle(510, 250)))},
        {"10% of a $6.66 pot is 66.6 units, rounded to 67",
         ?_assertMatch({settle, #{house_fee_units := 67, payout_units := 599}},
                       pay(?OWNER_A, battle(333, 1000)))},
        {"2.5% of a $10.18 pot is 25.45 units, rounded down to 25; catches rounding up",
         ?_assertMatch({settle, #{house_fee_units := 25, payout_units := 993}},
                       pay(?OWNER_A, battle(509, 250)))}
    ].

the_fee_comes_from_the_battle_not_the_league_test() ->
    ?assertMatch({settle, #{house_fee_units := 0, payout_units := 1000}},
                 pay(?OWNER_A, battle(500, 0))).

a_raised_stake_pays_the_fee_on_the_raised_pot_test() ->
    ?assertMatch({settle, #{pot_units := 4000, house_fee_units := 400,
                            payout_units := 3600}},
                 pay(?OWNER_B, battle(2000, 1000))).

pay(Winner, Battle) ->
    football_battle_settlement:decide(Battle, {pay_winner, Winner}).

battle(StakeUnits, HouseFeeBasisPoints) ->
    #{owner_a => ?OWNER_A, owner_b => ?OWNER_B, stake_units => StakeUnits,
      house_fee_basis_points => HouseFeeBasisPoints}.
