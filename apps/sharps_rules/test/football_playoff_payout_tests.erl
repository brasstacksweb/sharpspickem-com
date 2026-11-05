-module(football_playoff_payout_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BYE, 300).
-define(FIRST_ROUND, 300).
-define(QUARTERFINAL, 600).
-define(SEMIFINAL, 1100).
-define(CHAMPIONSHIP, 3000).

-define(BRACKET, lists:duplicate(4, ?BYE) ++ lists:duplicate(4, ?FIRST_ROUND)
                 ++ lists:duplicate(4, ?QUARTERFINAL) ++ lists:duplicate(2, ?SEMIFINAL)
                 ++ [?CHAMPIONSHIP]).

the_rulebook_example_test_() ->
    Paid = paid_units(pay_out(60000, [{Share, owned} || Share <- ?BRACKET])),
    [
        {"§12: on $600, a bye and a First Round win are $18 each",
         ?_assertEqual(lists:duplicate(8, 1800), lists:sublist(Paid, 8))},
        {"§12: a Quarterfinal is $36, a Semifinal $66, the Championship $180",
         ?_assertEqual([3600, 3600, 3600, 3600, 6600, 6600, 18000],
                       lists:nthtail(8, Paid))},
        {"§12: the fifteen payouts distribute the whole Prize Pool",
         ?_assertEqual(60000, lists:sum(Paid))}
    ].

the_last_slot_takes_the_rounding_dust_test() ->
    Paid = paid_units(pay_out(60001, [{Share, owned} || Share <- ?BRACKET])),
    ?assertEqual(60001, lists:sum(Paid)).

estimates_test() ->
    Rounds = [{bye, ?BYE}, {first_round, ?FIRST_ROUND}, {quarterfinal, ?QUARTERFINAL},
              {semifinal, ?SEMIFINAL}, {championship, ?CHAMPIONSHIP}],
    ?assertEqual([{bye, 1800}, {first_round, 1800}, {quarterfinal, 3600},
                  {semifinal, 6600}, {championship, 18000}],
                 football_playoff_payout:estimates(60000, Rounds)).

a_house_owned_winners_share_rolls_forward_test_() ->
    TwoUnownedByes = [{?BYE, owned}, {?BYE, owned},
                      {?BYE, house_owned}, {?BYE, house_owned}
                      | [{Share, owned} || Share <- lists:nthtail(4, ?BRACKET)]],
    Decisions = pay_out(60000, TwoUnownedByes),
    [
        {"as in 2024, two byes went to teams nobody owned",
         ?_assertEqual([{forfeited, rolls_into_later_rounds},
                        {forfeited, rolls_into_later_rounds}],
                       lists:sublist(Decisions, 3, 2))},
        {"the later rounds pay more than the table: 56400 x 3/88 is 1923, not 1800",
         ?_assertEqual({pay_units, 1923}, lists:nth(5, Decisions))},
        {"the House still ends at $0.00; catches a forfeit staying in the House",
         ?_assertEqual(60000, lists:sum(paid_units(Decisions)))}
    ].

a_house_owned_champion_refunds_the_rest_to_owners_test() ->
    ?assertEqual({forfeited, {refund_to_owners_units, 18000}},
                 slot_decision(18000, ?CHAMPIONSHIP, ?CHAMPIONSHIP, house_owned)).

a_round_worth_more_than_is_left_to_record_is_a_caller_bug_test() ->
    ?assertError(function_clause,
                 slot_decision(18000, ?CHAMPIONSHIP, ?SEMIFINAL, owned)).

pay_out(Pool, Slots) ->
    pay_out(Pool, lists:sum([Share || {Share, _Winner} <- Slots]), Slots).

pay_out(_Remaining, _Unrecorded, []) ->
    [];
pay_out(Remaining, Unrecorded, [{Share, Winner} | Later]) ->
    Decision = slot_decision(Remaining, Share, Unrecorded, Winner),
    [Decision | pay_out(Remaining - paid(Decision), Unrecorded - Share, Later)].

slot_decision(Remaining, RoundShare, Unrecorded, Winner) ->
    football_playoff_payout:decide(#{remaining_pool_units => Remaining,
                                     round_basis_points => RoundShare,
                                     unrecorded_basis_points => Unrecorded,
                                     winner => Winner}).

paid_units(Decisions) ->
    [paid(Decision) || Decision <- Decisions].

paid({pay_units, Units}) -> Units;
paid({forfeited, _Where}) -> 0.
