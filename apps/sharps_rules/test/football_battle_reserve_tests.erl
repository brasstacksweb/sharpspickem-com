-module(football_battle_reserve_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STAKE, 500).

the_rulebook_reserve_test_() ->
    [
        {"§11: holding four teams means keeping four stakes back",
         ?_assertEqual(2000, required(#{teams_held => 4}))},
        {"§11: one of the four playing twice in a week makes it five",
         ?_assertEqual(2500, required(#{teams_held => 4, extra_games_this_week => 1}))},
        {"§11: once no Battle can be created the reserve is released in full",
         ?_assertEqual(0, required(#{teams_held => 4, battle_season => battles_over}))}
    ].

headroom_test_() ->
    [
        {"a bid that leaves the reserve whole fits",
         ?_assertMatch({fits, #{reserve_units := 2500, headroom_units := 500}},
                       headroom(#{funds_units => 10000, cash_out_units => 7000,
                                  teams_gained => 1}))},
        {"a bid that spends into the reserve does not",
         ?_assertMatch({spends_into_the_reserve, #{headroom_units := -100}},
                       headroom(#{funds_units => 10000, cash_out_units => 7600,
                                  teams_gained => 1}))},
        {"spending to exactly the reserve fits; catches > in place of >=",
         ?_assertMatch({fits, #{headroom_units := 0}},
                       headroom(#{funds_units => 10000, cash_out_units => 7500,
                                  teams_gained => 1}))},
        {"teams gained are capped at the maximum; catches reserving for every queued add",
         ?_assertMatch({fits, #{teams_after := 5, reserve_units := 2500}},
                       headroom(#{funds_units => 10000, teams_gained => 10}))},
        {"a second game is a fact about the schedule, so the cap does not touch it",
         ?_assertMatch({fits, #{teams_after := 5, reserve_units := 3000}},
                       headroom(#{funds_units => 10000, teams_gained => 10,
                                  extra_games_this_week => 1}))},
        {"a stake already in escrow is not held back twice",
         ?_assertMatch({fits, #{escrow_credit_units := 1000, held_back_units := 1000}},
                       headroom(#{funds_units => 1000, escrow_units => 1000}))},
        {"escrow is credited only up to the reserve; catches escrow becoming spendable",
         ?_assertMatch({spends_into_the_reserve, #{escrow_credit_units := 2000,
                                                   headroom_units := -500}},
                       headroom(#{funds_units => 0, cash_out_units => 500,
                                  escrow_units => 5000}))},
        {"with the Battles over, everything is spendable",
         ?_assertMatch({fits, #{reserve_units := 0, headroom_units := 0}},
                       headroom(#{funds_units => 10000, cash_out_units => 10000,
                                  battle_season => battles_over}))}
    ].

margin_call_test_() ->
    [
        {"covering the reserve exactly is good standing; catches > in place of >=",
         ?_assertEqual({in_good_standing, #{required_units => 2000}},
                       margin_call(#{funds_units => 2000}))},
        {"a lost Battle that leaves funds short puts the owner in Margin Call",
         ?_assertEqual({in_margin_call, #{required_units => 2000, short_units => 300}},
                       margin_call(#{funds_units => 1700}))},
        {"escrow counts, or a new Battle would put both owners in Margin Call",
         ?_assertMatch({in_good_standing, _},
                       margin_call(#{funds_units => 1500, escrow_units => 500}))},
        {"once the Battles are over nobody is in Margin Call",
         ?_assertEqual({in_good_standing, #{required_units => 0}},
                       margin_call(#{funds_units => 0, battle_season => battles_over}))}
    ].

required(Overrides) ->
    football_battle_reserve:required_units(maps:merge(four_teams(), Overrides)).

headroom(Overrides) ->
    football_battle_reserve:headroom(
        maps:merge(four_teams(), maps:merge(#{cash_out_units => 0, escrow_units => 0,
                                              teams_gained => 0, max_teams => 5},
                                            Overrides))).

margin_call(Overrides) ->
    football_battle_reserve:margin_call(
        maps:merge(four_teams(), maps:merge(#{escrow_units => 0}, Overrides))).

four_teams() ->
    #{teams_held => 4, extra_games_this_week => 0, stake_units => ?STAKE,
      battle_season => battles_being_created}.
