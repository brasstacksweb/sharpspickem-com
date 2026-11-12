-module(football_season_progress_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_season_fills_the_bar_as_far_as_the_php_did_test() ->
    ?assertEqual([], golden:disagreements("decide_season_progress", fun port/1,
                                          fun php/2)).

port(#{<<"marks">> := Marks, <<"today">> := Today, <<"week">> := Week,
       <<"cfpWeek">> := FirstWeek}) ->
    {Numerator, Denominator} =
        football_season_progress:progress(#{marks => [mark(Mark) || Mark <- Marks],
                                            today => league_date(Today),
                                            week => week(Week),
                                            committee_first_week => FirstWeek}),
    as_the_php_prints_it(Numerator / Denominator).

php(_In, Progress) ->
    as_the_php_prints_it(Progress).

as_the_php_prints_it(Fraction) ->
    float_to_binary(float(Fraction), [{decimals, 12}]).

mark(#{<<"key">> := Key, <<"done">> := Reached, <<"on">> := On}) ->
    #{milestone => binary_to_existing_atom(Key), reached => Reached, on => dated(On)}.

dated(null) -> not_dated;
dated(On) -> league_date(On).

week(null) -> unknown;
week(Week) -> Week.

league_date(<<Year:4/binary, "-", Month:2/binary, "-", Day:2/binary>>) ->
    {league_local, {binary_to_integer(Year), binary_to_integer(Month),
                    binary_to_integer(Day)}}.
