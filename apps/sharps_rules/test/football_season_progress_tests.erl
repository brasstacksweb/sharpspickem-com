-module(football_season_progress_tests).

-include_lib("eunit/include/eunit.hrl").

progress_test_() ->
    [{"nothing reached is the start of the bar",
      ?_assertEqual({0, 1}, progress(0, #{}))},
     {"everything reached is the end of it",
      ?_assertEqual({1, 1}, progress(4, #{}))},
     {"the fill reaches the dot of the last milestone reached, not the next; catches "
      "counting reached milestones as segments",
      ?_assertEqual({1, 3}, progress(2, #{today => {league_local, {2026, 10, 4}}}))},
     {"and creeps toward the next by date",
      ?_assertEqual({1, 2}, progress(2, #{today => {league_local, {2026, 10, 19}}}))},
     {"but never reaches it: 92% of the way at most",
      ?_assertEqual({16, 25}, progress(2, #{today => {league_local, {2026, 12, 1}}}))},
     {"and never falls behind the dot it has reached",
      ?_assertEqual({1, 3}, progress(2, #{today => {league_local, {2026, 9, 1}}}))},
     {"the draft to the Committee's first poll goes by week, since nobody can date it",
      ?_assertEqual({1, 6}, progress(1, #{week => 6}))},
     {"against the week the Committee conventionally starts; catches measuring it "
      "against week 10",
      ?_assertEqual({1, 9}, progress(1, #{week => 4, committee_first_week => 10}))},
     {"with no week to go by it stays on the draft's dot",
      ?_assertEqual({0, 1}, progress(1, #{week => unknown}))},
     {"two dated milestones on the same day leave nothing to interpolate",
      ?_assertEqual({1, 3}, progress(2, #{closes_on => {league_local, {2026, 9, 1}},
                                          cfp_on => {league_local, {2026, 9, 1}}}))}].

progress(Reached, Changes) ->
    Season = maps:merge(#{today => {league_local, {2026, 9, 20}}, week => 3,
                          committee_first_week => 11,
                          cfp_on => {league_local, {2026, 10, 4}},
                          closes_on => {league_local, {2026, 11, 3}}},
                        Changes),
    Milestones = [{draft, {league_local, {2026, 8, 29}}},
                  {cfp_pricing, maps:get(cfp_on, Season)},
                  {closes, maps:get(closes_on, Season)},
                  {battles_end, {league_local, {2026, 12, 5}}}],
    Marks = [#{milestone => Milestone, reached => Index =< Reached,
               on => case Index =< Reached orelse Milestone =/= cfp_pricing of
                         true -> On;
                         false -> not_dated
                     end}
             || {Index, {Milestone, On}} <- lists:enumerate(Milestones)],
    football_season_progress:progress(
      maps:merge(maps:with([today, week, committee_first_week], Season),
                 #{marks => Marks})).
