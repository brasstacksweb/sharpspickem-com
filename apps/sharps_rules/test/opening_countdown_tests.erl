-module(opening_countdown_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, {utc, 1000000}).

countdown_test_() ->
    [{"nothing scheduled, nothing to count to",
      ?_assertEqual(nothing_to_count_to, opening_countdown:countdown(no_opening, ?NOW))},
     {"§6: an opening a day and a half away",
      ?_assertEqual(#{at => {utc, 1129600}, seconds_left => 129600, due => false,
                      shown_as => {days, 1, 12}},
                    countdown(129600))},
     {"one that has arrived is due and goes quiet rather than counting past zero",
      ?_assertEqual(#{at => {utc, 999000}, seconds_left => 0, due => true,
                      shown_as => settling_now},
                    countdown(-1000))},
     {"due at the very second it arrives; catches due only once it has passed",
      ?_assertMatch(#{due := true}, countdown(0))},
     {"a second before, not yet",
      ?_assertMatch(#{due := false, shown_as := under_a_minute}, countdown(1))}].

shown_as_test_() ->
    [{"59 seconds is under a minute; catches the minutes starting a second early",
      ?_assertMatch(#{shown_as := under_a_minute}, countdown(59))},
     {"a minute is counted in minutes",
      ?_assertMatch(#{shown_as := {minutes, 1}}, countdown(60))},
     {"59 minutes 59 seconds is still minutes, rounded down",
      ?_assertMatch(#{shown_as := {minutes, 59}}, countdown(3599))},
     {"an hour is hours and the minutes past it",
      ?_assertMatch(#{shown_as := {hours, 1, 0}}, countdown(3600))},
     {"hours and the minutes left over; catches the minutes not taken from the hour",
      ?_assertMatch(#{shown_as := {hours, 23, 59}}, countdown(86399))},
     {"a day is days and the hours past it",
      ?_assertMatch(#{shown_as := {days, 1, 0}}, countdown(86400))},
     {"days and the hours left over; catches the hours not taken from the day",
      ?_assertMatch(#{shown_as := {days, 10, 23}},
                    countdown(10 * 86400 + 23 * 3600 + 3599))}].

countdown(SecondsAhead) ->
    {utc, Now} = ?NOW,
    opening_countdown:countdown({utc, Now + SecondsAhead}, ?NOW).
