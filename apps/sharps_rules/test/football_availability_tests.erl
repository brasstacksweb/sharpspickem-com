-module(football_availability_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1760000000).
-define(MINUTES, 60).
-define(HOURS, 3600).
-define(DAYS, 86400).

game_state_test_() ->
    Kickoff = fun(Offset) -> (game(indiana, purdue, Offset, 12))#{completed := false} end,
    [
        {"an unscheduled game has not started",
         ?_assertEqual(upcoming, state((Kickoff(0))#{kickoff := unscheduled}))},
        {"a game kicking off later is upcoming",
         ?_assertEqual(upcoming, state(Kickoff(10 * ?MINUTES)))},
        {"a started game not marked complete is live",
         ?_assertEqual(live, state(Kickoff(-3 * ?HOURS)))},
        {"CFBD's completed flag makes it final",
         ?_assertEqual(final, state((Kickoff(-3 * ?HOURS))#{completed := true}))},
        {"a game never marked complete is final eight hours on, not locked for ever",
         ?_assertEqual(final, state(Kickoff(-8 * ?HOURS)))}
    ].

the_game_lock_test_() ->
    [
        {"31 minutes before kickoff a team can still be traded",
         ?_assertMatch(#{tradable := yes},
                       indiana([game(indiana, purdue, 31 * ?MINUTES, 13)]))},
        {"§6: from 30 minutes before kickoff it cannot; catches < for =<",
         ?_assertMatch(#{tradable := {no, kickoff_imminent}},
                       indiana([game(indiana, purdue, 30 * ?MINUTES, 13)]))},
        {"nor while its game is in progress",
         ?_assertMatch(#{tradable := {no, in_game}},
                       indiana([(game(indiana, purdue, -1 * ?HOURS, 13))#{
                                    completed := false}]))},
        {"Q18: the game-lock holds through the playoff",
         ?_assertMatch(#{tradable := {no, in_game}},
                       indiana([(game(indiana, oregon, -1 * ?HOURS, 1))#{
                                    completed := false, season_type := postseason}]))},
        {"§11: a live Battle stops a trade",
         ?_assertMatch(#{tradable := {no, live_battle}}, indiana([], #{battle => true}))}
    ].

the_price_must_still_stand_test_() ->
    Opened = {utc, ?NOW - 2 * ?DAYS},
    PlayedBeforeTheOpening = final(indiana, purdue, -3 * ?DAYS, 12),
    PlayedSinceTheOpening = final(indiana, purdue, -1 * ?DAYS, 13),
    [
        {"a team whose result the opening priced can be dealt with the House",
         ?_assertMatch(#{available := yes},
                       indiana([PlayedBeforeTheOpening], #{opened_at => Opened}))},
        {"§6: a result no opening has priced keeps it off the House's board",
         ?_assertMatch(#{available := {no, unpriced}, tradable := yes},
                       indiana([PlayedSinceTheOpening], #{opened_at => Opened}))},
        {"a team on a bye goes stale with the week, because its rank still moves",
         ?_assertMatch(#{available := {no, unpriced}},
                       on_a_bye([final(ohio_state, michigan, -1 * ?DAYS, 13)],
                                #{opened_at => Opened}))},
        {"but not while that week's slate is still being played",
         ?_assertMatch(#{available := yes},
                       on_a_bye([final(ohio_state, michigan, -1 * ?DAYS, 13),
                                 game(oregon, washington, 1 * ?DAYS, 13)],
                                #{opened_at => Opened}))},
        {"a game next week does not keep this week fresh",
         ?_assertMatch(#{available := {no, unpriced}},
                       on_a_bye([final(ohio_state, michigan, -1 * ?DAYS, 13),
                                 game(oregon, washington, 6 * ?DAYS, 14)],
                                #{opened_at => Opened}))},
        {"the playoff restarts at week 1, so it is left out of the week; catches it",
         ?_assertMatch(#{available := {no, unpriced}},
                       on_a_bye([final(ohio_state, michigan, -1 * ?DAYS, 14),
                                 (game(oregon, penn_state, 6 * ?DAYS, 1))#{
                                     season_type := postseason}],
                                #{opened_at => Opened}))}
    ].

before_the_first_opening_test_() ->
    [
        {"with nothing played, a team is available before any opening",
         ?_assertMatch(#{available := yes},
                       indiana([game(indiana, purdue, 2 * ?DAYS, 1)]))},
        {"once a result is in, no opening has priced it",
         ?_assertMatch(#{available := {no, no_opening_yet}},
                       indiana([final(indiana, purdue, -1 * ?DAYS, 1)]))}
    ].

the_reason_that_lasts_longest_is_given_test_() ->
    Opened = {utc, ?NOW - 2 * ?DAYS},
    [
        {"a live Battle before an unpriced result",
         ?_assertMatch(#{available := {no, live_battle}},
                       indiana([final(indiana, purdue, -1 * ?DAYS, 13)],
                               #{opened_at => Opened, battle => true}))},
        {"a priced team about to kick off is off the House's board too",
         ?_assertMatch(#{available := {no, kickoff_imminent}},
                       indiana([final(indiana, purdue, -3 * ?DAYS, 13),
                                game(indiana, michigan, 10 * ?MINUTES, 14)],
                               #{opened_at => Opened}))},
        {"an unpriced result before an imminent kickoff",
         ?_assertMatch(#{available := {no, unpriced}, tradable := {no, kickoff_imminent}},
                       indiana([final(indiana, purdue, -1 * ?DAYS, 13),
                                game(indiana, michigan, 10 * ?MINUTES, 14)],
                               #{opened_at => Opened}))}
    ].

indiana(Games) ->
    indiana(Games, #{}).

indiana(Games, Changes) ->
    answer_for(indiana, Games, Changes).

on_a_bye(Games, Changes) ->
    answer_for(purdue, Games, Changes).

answer_for(Team, Games, Changes) ->
    #{Team := Answer} = football_availability:decide(
        #{teams => [#{team => Team, live_battle => maps:get(battle, Changes, false)}],
          games => Games,
          opened_at => maps:get(opened_at, Changes, no_opening_yet),
          now => {utc, ?NOW},
          kickoff_lead_seconds => 30 * ?MINUTES}),
    Answer.

state(Game) ->
    football_availability:game_state(Game, {utc, ?NOW}).

game(Home, Away, SecondsFromNow, Week) ->
    #{home_team => Home, away_team => Away, kickoff => {utc, ?NOW + SecondsFromNow},
      completed => false, week => Week, season_type => regular}.

final(Home, Away, SecondsFromNow, Week) ->
    (game(Home, Away, SecondsFromNow, Week))#{completed := true}.
