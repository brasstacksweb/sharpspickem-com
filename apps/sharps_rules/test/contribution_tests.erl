-module(contribution_tests).

-include_lib("eunit/include/eunit.hrl").

request_test_() ->
    [{"§3: a top-up is requested, and buys nothing until it is confirmed",
      ?_assertEqual(requested, request(#{}))},
     {"not once the season is settled",
      ?_assertEqual({refused, season_settled},
                    request(#{season_settled => true, top_ups_enabled => false}))},
     {"§3: only if the Commissioner has enabled top-ups",
      ?_assertEqual({refused, top_ups_disabled},
                    request(#{top_ups_enabled => false, amount_units => 0}))},
     {"of at least one unit",
      ?_assertEqual({refused, amount_below_one_unit},
                    request(#{amount_units => 0, already_pending => true}))},
     {"one open request at a time",
      ?_assertEqual({refused, already_pending}, request(#{already_pending => true}))}].

confirm_test_() ->
    [{"§3: confirmed for what was requested",
      ?_assertEqual({confirm, 2500}, confirm(#{}))},
     {"or for what actually arrived",
      ?_assertEqual({confirm, 2000}, confirm(#{amount_units => 2000}))},
     {"never for nothing; catches a confirmation of zero",
      ?_assertEqual({refused, amount_below_one_unit},
                    confirm(#{amount_units => 0, season_settled => true}))},
     {"not once the season is settled",
      ?_assertEqual({refused, season_settled},
                    confirm(#{season_settled => true, contribution => not_found}))},
     {"only a contribution that exists",
      ?_assertEqual({refused, no_such_contribution}, confirm(#{contribution => not_found}))},
     {"only while it waits for an answer; catches a contribution credited twice",
      ?_assertEqual({refused, {already, confirmed}},
                    confirm(#{contribution => pending(#{status => confirmed})}))},
     {"whatever amount the second confirmation names",
      ?_assertEqual({refused, {already, reversed}},
                    confirm(#{contribution => pending(#{status => reversed}),
                              amount_units => 2000}))}].

reject_and_cancel_test_() ->
    [{"the Commissioner rejects a request still waiting",
      ?_assertEqual(rejected, contribution:reject(pending(#{})))},
     {"and an answered one is left as it is",
      ?_assertEqual(unchanged, contribution:reject(pending(#{status => confirmed})))},
     {"an owner withdraws their own request",
      ?_assertEqual(cancelled, contribution:cancel(<<"Ann">>, pending(#{})))},
     {"but nobody else's",
      ?_assertEqual(unchanged, contribution:cancel(<<"Bo">>, pending(#{})))},
     {"and not one already answered",
      ?_assertEqual(unchanged,
                    contribution:cancel(<<"Ann">>, pending(#{status => rejected})))}].

reverse_test_() ->
    Confirmed = pending(#{status => confirmed, confirmed_units => 2000}),
    [{"§13: a confirmed contribution is reversed for what was credited, not requested",
      ?_assertEqual({reverse, 2000}, reverse(#{contribution => Confirmed}))},
     {"not once the season is settled",
      ?_assertEqual({refused, season_settled},
                    reverse(#{contribution => Confirmed, season_settled => true}))},
     {"never twice",
      ?_assertEqual({refused, only_a_confirmed_contribution},
                    reverse(#{contribution => Confirmed#{status := reversed}}))},
     {"never a request that was not confirmed",
      ?_assertEqual({refused, only_a_confirmed_contribution},
                    reverse(#{contribution => pending(#{})}))},
     {"never one that does not exist",
      ?_assertEqual({refused, only_a_confirmed_contribution},
                    reverse(#{contribution => not_found}))}].

pending(Changes) ->
    maps:merge(#{owner => <<"Ann">>, kind => top_up, requested_units => 2500,
                 status => pending}, Changes).

request(Request) ->
    contribution:request(maps:merge(#{season_settled => false, top_ups_enabled => true,
                                      amount_units => 2500, already_pending => false},
                                    Request)).

confirm(Confirmation) ->
    contribution:confirm(maps:merge(#{season_settled => false, contribution => pending(#{}),
                                      amount_units => as_requested},
                                    Confirmation)).

reverse(Reversal) ->
    contribution:reverse(maps:merge(#{season_settled => false}, Reversal)).
