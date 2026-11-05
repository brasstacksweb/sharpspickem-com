-module(football_house_buyback_tests).

-include_lib("eunit/include/eunit.hrl").

the_three_stages_test_() ->
    [
        {"§8: from the start of the season the House buys any Top 25 team",
         ?_assertEqual(yes, will_buy(buys_the_top_25, {ranked, 25}))},
        {"§8: after the first date it buys teams ranked 1-12",
         ?_assertEqual(yes, will_buy(buys_the_top_12, {ranked, 12}))},
        {"§8: and not 13-25; catches >= 12 in place of > 12",
         ?_assertEqual({no, {ranked_outside_the_top_12, 13}},
                       will_buy(buys_the_top_12, {ranked, 13}))},
        {"§8: after the second date it buys nothing, not even the top team",
         ?_assertEqual({no, house_stopped_buying}, will_buy(buys_nothing, {ranked, 1}))},
        {"§8: unranked teams are never bought, at any stage",
         ?_assertEqual([{no, unranked}, {no, unranked}],
                       [will_buy(Stage, unranked) || Stage <- [buys_the_top_25,
                                                               buys_the_top_12]])}
    ].

a_sale_test_() ->
    [
        {"§8 pays Market Value in full, and carries the seller's basis for the record",
         ?_assertEqual({sell, #{price_units => 4200, basis_units => 3000}},
                       sell(#{}))},
        {"only the owner can sell",
         ?_assertEqual({refused, not_your_team},
                       sell(#{team => not_owned_by_seller}))},
        {"the stage is checked when the sale settles, not only when it is queued",
         ?_assertEqual({refused, {ranked_outside_the_top_12, 18}},
                       sell(#{stage => buys_the_top_12, rank => {ranked, 18}}))},
        {"§8: no partial buybacks; a House short by one unit refuses",
         ?_assertEqual({refused, house_cannot_cover},
                       sell(#{house_balance_units => 4199}))},
        {"a House holding exactly the Market Value pays it; catches =< in place of <",
         ?_assertMatch({sell, _},
                       sell(#{house_balance_units => 4200}))}
    ].

forecast_test_() ->
    [
        {"the first date, three days away, narrows the House to the top 12",
         ?_assertEqual({narrows, #{to => buys_the_top_12,
                                   on => {league_local, {2026, 10, 18}},
                                   in_days => 3}},
                       forecast(buys_the_top_25, {2026, 10, 18}, {2026, 10, 15}))},
        {"the second date closes it",
         ?_assertMatch({narrows, #{to := buys_nothing}},
                       forecast(buys_the_top_12, {2026, 11, 29}, {2026, 11, 1}))},
        {"on the day itself it is zero days away",
         ?_assertMatch({narrows, #{in_days := 0}},
                       forecast(buys_the_top_25, {2026, 10, 18}, {2026, 10, 18}))},
        {"days count across a month end; catches subtracting day numbers",
         ?_assertMatch({narrows, #{in_days := 3}},
                       forecast(buys_the_top_25, {2026, 11, 1}, {2026, 10, 29}))},
        {"a date already past goes quiet rather than counting below zero",
         ?_assertEqual(nothing_to_warn,
                       forecast(buys_the_top_25, {2026, 10, 18}, {2026, 10, 19}))},
        {"nothing narrows once the House has stopped buying",
         ?_assertEqual(nothing_to_warn,
                       forecast(buys_nothing, {2026, 12, 1}, {2026, 11, 1}))},
        {"a league still in setup has no date to count to",
         ?_assertEqual(nothing_to_warn,
                       football_house_buyback:forecast(
                           #{stage => buys_the_top_25, next_boundary => not_set,
                             today => {league_local, {2026, 8, 1}}}))}
    ].

will_buy(Stage, Rank) ->
    football_house_buyback:will_buy(Stage, Rank).

sell(Overrides) ->
    NinthRankedTeamBoughtFor30 = #{team => {owned_by_seller, #{basis_units => 3000}},
                                   stage => buys_the_top_25,
                                   rank => {ranked, 9},
                                   market_value_units => 4200,
                                   house_balance_units => 100000},
    football_house_buyback:decide(maps:merge(NinthRankedTeamBoughtFor30, Overrides)).

forecast(Stage, Boundary, Today) ->
    football_house_buyback:forecast(#{stage => Stage,
                                      next_boundary => {league_local, Boundary},
                                      today => {league_local, Today}}).
