-module(football_portfolio_tests).

-include_lib("eunit/include/eunit.hrl").

value_test_() ->
    [{"§4: Portfolio Value is Available Funds plus what the House would pay for every team",
      ?_assertMatch(#{team_value_units := 4300, portfolio_value_units := 6300},
                    value(#{}))},
     {"Alpha is Portfolio Value less every Contribution and every Adjustment",
      ?_assertMatch(#{alpha_units := 6300 - 5000 - 300}, value(#{}))},
     {"§13: an Adjustment moves Portfolio Value and leaves Alpha where it was; catches "
      "Alpha leaving Adjustments out",
      ?_assertEqual(maps:get(alpha_units, value(#{})),
                    maps:get(alpha_units, value(#{cash_units => 2000 - 500,
                                                  adjustments_units => 300 - 500})))},
     {"a Contribution likewise; catches Alpha leaving Contributions out",
      ?_assertEqual(maps:get(alpha_units, value(#{})),
                    maps:get(alpha_units, value(#{cash_units => 2000 + 2500,
                                                  contributed_units => 5000 + 2500})))},
     {"§5: an unranked team is worth nothing",
      ?_assertMatch(#{team_value_units := 0},
                    value(#{holdings => [#{rank => unranked, market_value_units => 0}]}))},
     {"§8: from the first buyback date a team ranked 13th is worth nothing, since the "
      "House will not buy it",
      ?_assertMatch(#{team_value_units := 2500},
                    value(#{stage => buys_the_top_12}))},
     {"and from the second date every team is worth nothing, leaving the cash",
      ?_assertMatch(#{team_value_units := 0, portfolio_value_units := 2000},
                    value(#{stage => buys_nothing}))}].

standings_test_() ->
    [{"§4: Alpha ranks the league, not Portfolio Value",
      ?_assertEqual([{<<"Bo">>, 1}, {<<"Ann">>, 2}],
                    ranks([{<<"Ann">>, 100, 90000}, {<<"Bo">>, 200, 10000}]))},
     {"equal Alphas share a rank, so a tie at the top is co-champions; catches ranking "
      "a tie by Portfolio Value",
      ?_assertEqual([{<<"Bo">>, 1}, {<<"Ann">>, 1}, {<<"Cy">>, 3}],
                    ranks([{<<"Ann">>, 200, 10000}, {<<"Bo">>, 200, 20000},
                           {<<"Cy">>, 100, 90000}]))},
     {"and the rank after a tie skips the places the tie took",
      ?_assertEqual([{<<"Ann">>, 1}, {<<"Bo">>, 2}, {<<"Cy">>, 2}, {<<"Di">>, 4}],
                    ranks([{<<"Ann">>, 300, 0}, {<<"Bo">>, 200, 0}, {<<"Cy">>, 200, 0},
                           {<<"Di">>, -100, 0}]))},
     {"owners tied on both are listed in the order they joined",
      ?_assertEqual([{<<"Cy">>, 1}, {<<"Ann">>, 1}],
                    ranks([{<<"Cy">>, 0, 0}, {<<"Ann">>, 0, 0}]))}].

value(Changes) ->
    football_portfolio:value(
      maps:merge(#{stage => buys_the_top_25,
                   holdings => [#{rank => {ranked, 10}, market_value_units => 2500},
                                #{rank => {ranked, 13}, market_value_units => 1800}],
                   cash_units => 2000, contributed_units => 5000, adjustments_units => 300},
                 Changes)).

ranks(Owners) ->
    [{Owner, Rank}
     || #{owner := Owner, rank := Rank}
            <- football_portfolio:standings(
                 [#{owner => Owner, alpha_units => Alpha, portfolio_value_units => Value}
                  || {Owner, Alpha, Value} <- Owners])].
