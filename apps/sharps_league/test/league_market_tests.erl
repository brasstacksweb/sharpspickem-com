-module(league_market_tests).

-include_lib("eunit/include/eunit.hrl").

cancelling_test_() ->
    State = with_bids([{1, <<"Ann">>, 1}, {2, <<"Bo">>, 1}]),
    [
        {"an owner cancels their own pending order",
         ?_assertEqual([{order_cancelled, 1}],
                       league_market:cancel(<<"Ann">>, 1, State))},
        {"and nobody else's; catches cancelling by number alone",
         ?_assertEqual([], league_market:cancel(<<"Ann">>, 2, State))}
    ].

reordering_test_() ->
    State = with_bids([{1, <<"Ann">>, 1}, {2, <<"Ann">>, 2}, {3, <<"Ann">>, 3},
                       {4, <<"Bo">>, 1}]),
    TiedBids = with_bids([{5, <<"Cy">>, 2}, {6, <<"Cy">>, 2}]),
    [
        {"§7: moving a bid up swaps its rank with the bid above it",
         ?_assertEqual([{orders_reprioritised, [{2, 1}, {1, 2}]}],
                       league_market:reorder(<<"Ann">>, 2, up, State))},
        {"and down with the bid below it",
         ?_assertEqual([{orders_reprioritised, [{2, 3}, {3, 2}]}],
                       league_market:reorder(<<"Ann">>, 2, down, State))},
        {"the top bid cannot move up; catches wrapping around",
         ?_assertEqual([], league_market:reorder(<<"Ann">>, 1, up, State))},
        {"another owner's bids are not neighbours; catches ranking across owners",
         ?_assertEqual([], league_market:reorder(<<"Ann">>, 3, down, State))},
        {"two bids ranked the same still move apart, as the PHP does",
         ?_assertEqual([{orders_reprioritised, [{6, 1}, {5, 2}]}],
                       league_market:reorder(<<"Cy">>, 6, up, TiedBids))},
        {"only a pending bid of your own",
         ?_assertEqual({refused, not_your_pending_bid},
                       league_market:reorder(<<"Bo">>, 2, up, State))}
    ].

with_bids(Bids) ->
    Opened = league_state:new({league_opened,
                               #{settings => #{}, commissioner => <<"Ann">>,
                                 owners => [<<"Ann">>, <<"Bo">>, <<"Cy">>],
                                 teams => [<<"Utah">>]}}),
    lists:foldl(fun({Number, Owner, Priority}, State) ->
                        league_state:apply_event(
                            {order_queued, #{number => Number, owner => Owner,
                                             team => <<"Utah">>, kind => bid,
                                             amount_units => 500, conditional => false,
                                             priority => Priority}}, State)
                end, Opened, Bids).
