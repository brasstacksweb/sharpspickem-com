-module(football_pricing_open_tests).

-include_lib("eunit/include/eunit.hrl").

next_test_() ->
    [{"§7: once its poll has landed the opening is scheduled, and exact",
      ?_assertEqual({exact, {utc, 1800000000}},
                    next(#{scheduled => {utc, 1800000000}}))},
     {"the AP poll follows the week's last game; the board reprices the next morning",
      ?_assertEqual({estimated, at({2026, 9, 7}, {9, 0, 0})},
                    next(#{last_game => at({2026, 9, 5}, {22, 30, 0})}))},
     {"a week ending on Labour Day Monday reprices on the Wednesday; catches assuming "
      "a Sunday poll",
      ?_assertEqual({estimated, at({2026, 9, 9}, {9, 0, 0})},
                    next(#{last_game => at({2026, 9, 7}, {20, 0, 0}),
                           now => at({2026, 9, 7}, {21, 0, 0})}))},
     {"§7: from week 11 the Committee publishes on the Tuesday, the board reprices "
      "Wednesday",
      ?_assertEqual({estimated, at({2026, 11, 11}, {9, 0, 0})},
                    next(#{week => 11, last_game => at({2026, 11, 7}, {22, 30, 0})}))},
     {"a Committee week whose last game falls on the Tuesday itself; catches starting "
      "the search a day late",
      ?_assertEqual({estimated, at({2026, 11, 11}, {9, 0, 0})},
                    next(#{week => 12, last_game => at({2026, 11, 10}, {19, 0, 0}),
                           now => at({2026, 11, 10}, {20, 0, 0})}))},
     {"week 10 is still the AP's; catches the Committee starting a week early",
      ?_assertEqual({estimated, at({2026, 11, 2}, {9, 0, 0})},
                    next(#{week => 10, last_game => at({2026, 10, 31}, {22, 30, 0})}))},
     {"no game this week counts from today",
      ?_assertEqual({estimated, at({2026, 9, 3}, {6, 30, 0})},
                    next(#{last_game => no_game, now => at({2026, 9, 1}, {8, 0, 0}),
                           open_time => {6, 30}}))},
     {"a poll running late never names a moment behind us",
      ?_assertEqual({estimated, at({2026, 9, 9}, {9, 0, 0})},
                    next(#{now => at({2026, 9, 8}, {10, 0, 0})}))},
     {"and the moment itself is behind us, so the next morning; catches stopping on "
      "an opening that is now",
      ?_assertEqual({estimated, at({2026, 9, 8}, {9, 0, 0})},
                    next(#{now => at({2026, 9, 7}, {9, 0, 0})}))}].

next(Changes) ->
    football_pricing_open:next(
      maps:merge(#{scheduled => not_scheduled, week => 2,
                   last_game => at({2026, 9, 5}, {22, 30, 0}),
                   now => at({2026, 9, 6}, {12, 0, 0}), open_time => {9, 0}},
                 Changes)).

at(Date, Time) ->
    {league_local, {Date, Time}}.
