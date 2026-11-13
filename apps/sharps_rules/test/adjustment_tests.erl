-module(adjustment_tests).

-include_lib("eunit/include/eunit.hrl").

decide_test_() ->
    [{"§13: an Adjustment moves an owner's funds either way, with its reason",
      ?_assertEqual({adjust, -1500, <<"Recording error">>},
                    decide(#{amount_units => -1500}))},
     {"the reason is kept as stated, less the space around it",
      ?_assertEqual({adjust, 1500, <<"Recording error">>},
                    decide(#{reason => <<"  Recording error\n">>}))},
     {"never for nothing",
      ?_assertEqual({refused, zero_amount},
                    decide(#{amount_units => 0, reason => <<>>}))},
     {"§13: never without a stated reason",
      ?_assertEqual({refused, reason_required},
                    decide(#{reason => <<" \t">>, in_the_league => false}))},
     {"only to an owner in the league",
      ?_assertEqual({refused, not_in_the_league},
                    decide(#{in_the_league => false, season_settled => true}))},
     {"not once the season is settled",
      ?_assertEqual({refused, season_settled}, decide(#{season_settled => true}))}].

decide(Adjustment) ->
    adjustment:decide(maps:merge(#{amount_units => 1500, reason => <<"Recording error">>,
                                   in_the_league => true, season_settled => false},
                                 Adjustment)).
