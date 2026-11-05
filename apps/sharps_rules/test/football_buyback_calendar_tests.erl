-module(football_buyback_calendar_tests).

-include_lib("eunit/include/eunit.hrl").

a_league_set_up_as_recommended_has_no_warnings_test() ->
    ?assertEqual([], warnings(#{})).

closing_during_championship_week_test_() ->
    [
        {"§8 recommends closing before championship week; closing on its first day warns",
         ?_assertEqual([{closes_during_championship_week,
                         #{closes_on => {league_local, {2026, 11, 30}},
                           championship_week_starts => {league_local, {2026, 11, 30}}}}],
                       warnings(#{closes_on => {league_local, {2026, 11, 30}}}))},
        {"the day before does not; catches > for >=",
         ?_assertEqual([], warnings(#{closes_on => {league_local, {2026, 11, 29}}}))},
        {"dates compare across a month end; catches comparing the day alone",
         ?_assertMatch([{closes_during_championship_week, _}],
                       warnings(#{closes_on => {league_local, {2026, 12, 1}}}))},
        {"with championship week not yet known there is nothing to say",
         ?_assertEqual([], warnings(#{closes_on => {league_local, {2026, 12, 5}},
                                      championship_week_starts => unknown}))},
        {"nor with no close date set",
         ?_assertEqual([], warnings(#{closes_on => not_set}))}
    ].

dates_already_passed_test_() ->
    [
        {"a narrowing date of today means the season would begin narrowed",
         ?_assertEqual([{already_passed, narrows_on, {league_local, {2026, 8, 20}}}],
                       warnings(#{narrows_on => {league_local, {2026, 8, 20}}}))},
        {"both dates can have passed",
         ?_assertMatch([{already_passed, narrows_on, _}, {already_passed, closes_on, _}],
                       warnings(#{narrows_on => {league_local, {2026, 8, 1}},
                                  closes_on => {league_local, {2026, 8, 2}}}))},
        {"a date not yet set has not passed",
         ?_assertEqual([], warnings(#{narrows_on => not_set}))},
        {"once the draft has started the dates are frozen, so there is nothing to act on",
         ?_assertEqual([], warnings(#{narrows_on => {league_local, {2026, 8, 1}},
                                      season => started}))}
    ].

warnings(Overrides) ->
    SetUpAsRecommended = #{narrows_on => {league_local, {2026, 10, 18}},
                           closes_on => {league_local, {2026, 11, 22}},
                           championship_week_starts => {league_local, {2026, 11, 30}},
                           today => {league_local, {2026, 8, 20}},
                           season => not_started},
    football_buyback_calendar:warnings(maps:merge(SetUpAsRecommended, Overrides)).
