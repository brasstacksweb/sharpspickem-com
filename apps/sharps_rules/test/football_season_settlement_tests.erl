-module(football_season_settlement_tests).

-include_lib("eunit/include/eunit.hrl").

the_rulebook_settlement_test_() ->
    [{"§13: one payment per owner, of their whole final balance",
      ?_assertEqual({settle, [{<<"Bo">>, 30000}, {<<"Ann">>, 12000}]},
                    decide(#{balances => [{<<"Ann">>, 12000}, {<<"Bo">>, 30000}]}))},
     {"an owner who ends below zero owes the league, and is settled the same way",
      ?_assertEqual({settle, [{<<"Ann">>, 500}, {<<"Bo">>, -200}]},
                    decide(#{balances => [{<<"Ann">>, 500}, {<<"Bo">>, -200}]}))},
     {"nothing for an owner holding nothing",
      ?_assertEqual({settle, [{<<"Bo">>, 100}]},
                    decide(#{balances => [{<<"Ann">>, 0}, {<<"Bo">>, 100}]}))},
     {"equal balances in the owners' order; catches an unstable sort",
      ?_assertEqual({settle, [{<<"Cy">>, 900}, {<<"Ann">>, 100}, {<<"Bo">>, 100}]},
                    decide(#{balances => [{<<"Ann">>, 100}, {<<"Bo">>, 100},
                                          {<<"Cy">>, 900}]}))}].

not_ready_test_() ->
    [{"§12: not before the Prize Pool exists",
      ?_assertEqual({refused, {not_ready, [prize_pool_not_frozen]}},
                    decide(#{prize_pool => not_frozen}))},
     {"§13: not while a playoff payout is still to be recorded",
      ?_assertEqual({refused, {not_ready, [{payouts_not_recorded, 3}]}},
                    decide(#{slots_outstanding => 3, house_units => 900}))},
     {"§13: not while the House holds anything, once every payout is recorded",
      ?_assertEqual({refused, {not_ready, [{house_still_holds_units, 1}]}},
                    decide(#{house_units => 1}))},
     {"§13: and once only",
      ?_assertEqual({refused, already_settled}, decide(#{settled => true}))}].

decide(Season) ->
    football_season_settlement:decide(
      maps:merge(#{prize_pool => frozen, slots_outstanding => 0, house_units => 0,
                   settled => false, balances => [{<<"Ann">>, 100}]},
                 Season)).
