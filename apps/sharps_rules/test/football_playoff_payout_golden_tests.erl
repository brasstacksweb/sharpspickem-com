-module(football_playoff_payout_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_playoff_share_pays_what_the_php_paid_test() ->
    ?assertEqual([], golden:disagreements("decide_playoff_share", fun port/1, fun php/2)).

every_recorded_estimate_matches_the_php_test() ->
    ?assertEqual([], golden:disagreements("decide_payout_estimates",
                                          fun estimates/1, fun php_estimates/2)).

port(#{<<"remainingPool">> := Remaining, <<"thisPct">> := RoundPercent,
       <<"unrecordedPct">> := UnrecordedPercent, <<"forfeited">> := Forfeited}) ->
    football_playoff_payout:decide(#{remaining_pool_units => Remaining,
                                     round_basis_points => basis_points(RoundPercent),
                                     unrecorded_basis_points =>
                                         basis_points(UnrecordedPercent),
                                     winner => winner(Forfeited)}).

winner(true) -> house_owned;
winner(false) -> owned.

php(#{<<"forfeited">> := false}, #{<<"amount">> := Amount}) ->
    {pay_units, Amount};
php(#{<<"forfeited">> := true}, #{<<"is_last">> := false}) ->
    {forfeited, rolls_into_later_rounds};
php(#{<<"forfeited">> := true},
    #{<<"is_last">> := true, <<"remainder_after">> := Left}) ->
    {forfeited, {refund_to_owners_units, Left}}.

estimates(#{<<"baseCents">> := Pool, <<"rounds">> := Rounds}) ->
    maps:from_list(football_playoff_payout:estimates(
        Pool, [{Round, basis_points(Percent)}
               || Round := #{<<"pct">> := Percent} <- Rounds])).

php_estimates(_In, Estimates) ->
    Estimates.

basis_points(Percent) ->
    round(Percent * 100).
