-module(league_corrections_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, {utc, 5000}).

buy_ins_test_() ->
    [{"§3: every owner's buy-in waits for the Commissioner from the day the league opens",
      ?_assertEqual([1, 2], [league_state:pending_contribution(Owner, opened())
                             || Owner <- [<<"Ann">>, <<"Bo">>]])},
     {"and is credited for what arrived, against the contribution it confirms",
      ?_assertMatch([#{owner := <<"Bo">>, type := contribution, amount_units := 9000,
                       related := {contribution, 2}}],
                    league_state:owner_ledger(
                      after_acts(opened(), [{<<"Ann">>, {confirm_contribution, 2, 9000}}])))},
     {"a league without a buy-in opens with nothing waiting",
      ?_assertEqual(0, league_state:contributions_pending(opened(#{buy_in_units => 0})))}].

top_up_test_() ->
    [{"§3: a top-up waits until the Commissioner confirms it",
      ?_assertEqual({1000, 0},
                    {funds(<<"Bo">>, funded([{<<"Bo">>, {request_funds, 500}}])),
                     league_state:contributions_pending(
                       funded([{<<"Bo">>, {request_funds, 500}},
                               {<<"Ann">>, {confirm_contribution, 3, as_requested}}]))})},
     {"one at a time",
      ?_assertEqual({refused, already_pending},
                    act(<<"Bo">>, {request_funds, 500},
                        funded([{<<"Bo">>, {request_funds, 500}}])))},
     {"only where the Commissioner has enabled them",
      ?_assertEqual({refused, top_ups_disabled},
                    act(<<"Bo">>, {request_funds, 500},
                        opened(#{top_ups_enabled => false})))},
     {"an owner withdraws their own",
      ?_assertEqual(0, league_state:contributions_pending(
                         funded([{<<"Bo">>, {request_funds, 500}},
                                 {<<"Bo">>, {cancel_fund_request, 3}}])))},
     {"and the Commissioner rejects one, crediting nothing",
      ?_assertEqual({1000, 0},
                    {funds(<<"Bo">>, funded([{<<"Bo">>, {request_funds, 500}},
                                             {<<"Ann">>, {reject_contribution, 3}}])),
                     league_state:contributions_pending(
                       funded([{<<"Bo">>, {request_funds, 500}},
                               {<<"Ann">>, {reject_contribution, 3}}]))})},
     {"answering a contribution is the Commissioner's alone",
      [?_assertEqual({refused, not_the_commissioner}, act(<<"Bo">>, Command, opened()))
       || Command <- [{confirm_contribution, 2, as_requested}, {reject_contribution, 2},
                      {reverse_contribution, 1}, {adjust_funds, <<"Bo">>, 100, <<"Fix">>}]]}].

reversal_test_() ->
    Reversed = funded([{<<"Ann">>, {reverse_contribution, 2}}]),
    [{"§13: a reversal takes back what was credited, against the contribution",
      ?_assertMatch(#{owner := <<"Bo">>, type := reversal, amount_units := -1000,
                      balance_after_units := 0, related := {contribution, 2}},
                    lists:last(league_state:owner_ledger(Reversed)))},
     {"never twice",
      ?_assertEqual({refused, only_a_confirmed_contribution},
                    act(<<"Ann">>, {reverse_contribution, 2}, Reversed))},
     {"§12: and a reversed contribution earns no share of a refunded Prize Pool",
      ?_assertEqual([{<<"Ann">>, 1000}, {<<"Bo">>, 0}],
                    league_state:contributions(Reversed))},
     {"an owner who has spent it is taken below zero, and owes it",
      ?_assertEqual(-400,
                    funds(<<"Bo">>,
                          after_acts(lists:foldl(fun league_state:apply_event/2, funded([]),
                                                 [{team_bought, #{owner => <<"Bo">>,
                                                                  team => <<"Utah">>,
                                                                  price_units => 400}}]),
                                     [{<<"Ann">>, {reverse_contribution, 2}}])))},
     {"the books stay whole",
      ?_assertEqual([], league_invariants:broken(?NOW, Reversed))}].

adjustment_test_() ->
    Adjusted = funded([{<<"Ann">>, {adjust_funds, <<"Bo">>, -1500,
                                    <<"  Charged twice for Utah ">>}}]),
    [{"§13: an Adjustment moves the balance and says why, on the owner's funds record",
      ?_assertMatch(#{owner := <<"Bo">>, type := commissioner_adjustment,
                      amount_units := -1500, balance_after_units := -500,
                      related := none, reason := <<"Charged twice for Utah">>},
                    lists:last(league_state:owner_ledger(Adjusted)))},
     {"it is no Contribution, so the Prize Pool's refund ignores it",
      ?_assertEqual([{<<"Ann">>, 1000}, {<<"Bo">>, 1000}],
                    league_state:contributions(Adjusted))},
     {"only to an owner in the league",
      ?_assertEqual({refused, not_in_the_league},
                    act(<<"Ann">>, {adjust_funds, <<"Cy">>, 100, <<"Fix">>}, opened()))},
     {"the books stay whole",
      ?_assertEqual([], league_invariants:broken(?NOW, Adjusted))}].

settlement_test_() ->
    [{"§13: the season is not settled over a contribution still waiting",
      ?_assertEqual({refused, {not_ready, [{contributions_pending, 1}]}},
                    act(<<"Ann">>, settle_season,
                        finished([{<<"Bo">>, {request_funds, 500}}])))},
     {"an owner adjusted below zero is settled for what they owe",
      ?_assertEqual({ok, [{season_settled, [{<<"Ann">>, 1000}, {<<"Bo">>, -200}]}]},
                    act(<<"Ann">>, settle_season,
                        finished([{<<"Ann">>, {adjust_funds, <<"Bo">>, -1200,
                                               <<"Owes for a trade">>}}])))},
     {"nothing is corrected once it is settled",
      [?_assertEqual({refused, season_settled}, act(Actor, Command, settled()))
       || {Actor, Command} <- [{<<"Ann">>, {reverse_contribution, 1}},
                               {<<"Ann">>, {adjust_funds, <<"Bo">>, 100, <<"Fix">>}},
                               {<<"Bo">>, {request_funds, 500}}]]}].

opened() ->
    opened(#{}).

opened(Settings) ->
    league_state:new({league_opened,
                      #{settings => maps:merge(#{max_teams => 5, stake_units => 700,
                                                 house_fee_basis_points => 2000,
                                                 buy_in_units => 1000},
                                               Settings),
                        commissioner => <<"Ann">>, owners => [<<"Ann">>, <<"Bo">>],
                        teams => [<<"Utah">>]}}).

funded(Acts) ->
    after_acts(opened(), [{<<"Ann">>, {confirm_contribution, 1, as_requested}},
                          {<<"Ann">>, {confirm_contribution, 2, as_requested}} | Acts]).

finished(Acts) ->
    after_acts(lists:foldl(fun league_state:apply_event/2, funded([]),
                           [{prize_pool_frozen, 0}
                            | [{playoff_share_forfeited, #{round => Round,
                                                           team => <<"Utah">>}}
                               || {Round, _Share, Games}
                                      <- football_playoff_payout:schedule(),
                                  _Game <- lists:seq(1, Games)]]),
               Acts).

settled() ->
    after_acts(finished([]), [{<<"Ann">>, settle_season}]).

after_acts(State, Acts) ->
    lists:foldl(fun({Actor, Command}, Before) ->
                        {ok, Events} = act(Actor, Command, Before),
                        lists:foldl(fun league_state:apply_event/2, Before, Events)
                end, State, Acts).

act(Actor, Command, State) ->
    league_commands:decide(#{at => ?NOW, actor => Actor, command => Command}, State).

funds(Owner, State) ->
    league_state:funds(Owner, State).
