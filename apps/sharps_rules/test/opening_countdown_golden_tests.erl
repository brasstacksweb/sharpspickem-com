-module(opening_countdown_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_countdown_counts_as_the_php_did_test() ->
    ?assertEqual([], golden:disagreements("decide_opening_countdown", fun port/1,
                                          fun php/2)).

port(#{<<"settles_at_ts">> := SettlesAt, <<"nowTs">> := Now}) ->
    opening_countdown:countdown(opening(SettlesAt), {utc, Now}).

opening(null) -> no_opening;
opening(SettlesAt) -> {utc, SettlesAt}.

php(_In, null) ->
    nothing_to_count_to;
php(_In, #{<<"at_ts">> := At, <<"seconds">> := Seconds, <<"due">> := Due,
           <<"phrase">> := Phrase}) ->
    #{at => {utc, At}, seconds_left => Seconds, due => Due, shown_as => shown_as(Phrase)}.

shown_as(<<"settling now">>) ->
    settling_now;
shown_as(<<"in under a minute">>) ->
    under_a_minute;
shown_as(<<"in ", Counted/binary>>) ->
    case binary:split(Counted, <<" ">>) of
        [Minutes] -> {minutes, leading_number(Minutes, <<"m">>)};
        [Larger, Smaller] -> larger_and_smaller(Larger, Smaller)
    end.

larger_and_smaller(Larger, Smaller) ->
    case binary:last(Larger) of
        $h -> {hours, leading_number(Larger, <<"h">>), leading_number(Smaller, <<"m">>)};
        $d -> {days, leading_number(Larger, <<"d">>), leading_number(Smaller, <<"h">>)}
    end.

leading_number(Counted, Unit) ->
    [Number, <<>>] = binary:split(Counted, Unit),
    binary_to_integer(Number).
