-module(league_playoff_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LAST_REGULAR_FINAL, 2000).

-define(FIRST_ROUND_FINAL, 3000).

-define(CHAMPIONSHIP_FINAL, 4000).

the_prize_pool_test_() ->
    [{"§12: not while a regular-season game is still to be decided",
      ?_assertEqual([], frozen_at(?LAST_REGULAR_FINAL - 1))},
     {"§12: the House's balance when the regular season ends",
      ?_assertEqual([{prize_pool_frozen, 20000}], frozen_at(?LAST_REGULAR_FINAL))},
     {"and only once; catches a re-snapshot after the postseason has moved the House",
      ?_assertEqual([], frozen_at_again(?LAST_REGULAR_FINAL + 1))}].

a_playoff_win_test_() ->
    Won = caught_up(?FIRST_ROUND_FINAL, season()),
    [{"§12: pays the team's owner its share; 20000 less the byes still owed, x 3/88",
      ?_assertEqual([{playoff_share_paid, #{round => first_round, team => <<"Utah">>,
                                            owner => <<"Ann">>, amount_units => 600}}],
                    Won)},
     {"once; catches a slot paid again at the next catch-up",
      ?_assertEqual([], caught_up(?FIRST_ROUND_FINAL + 1, with(season(), Won)))},
     {"a team traded before it wins earns for its new owner",
      ?_assertMatch([{playoff_share_paid, #{owner := <<"Bo">>}}],
                    caught_up(?FIRST_ROUND_FINAL,
                              with(season(), [{team_dropped, #{owner => <<"Ann">>,
                                                               team => <<"Utah">>}},
                                              {team_added, #{owner => <<"Bo">>,
                                                             team => <<"Utah">>}}])))},
     {"nothing before the game is final",
      ?_assertEqual([], caught_up(?FIRST_ROUND_FINAL - 1, season()))}].

a_house_owned_winner_test_() ->
    Unowned = with(season(), [{team_dropped, #{owner => <<"Ann">>, team => <<"Utah">>}}]),
    [{"§12: forfeits a First Round share to the rounds still to be paid",
      ?_assertEqual([{playoff_share_forfeited, #{round => first_round,
                                                 team => <<"Utah">>}}],
                    caught_up(?FIRST_ROUND_FINAL, Unowned))},
     {"§12: and as champion returns the rest to the owners, as they contributed: the "
      "20000 less the 13400 still owed to the slots not yet recorded",
      ?_assertEqual([{playoff_share_forfeited, #{round => championship,
                                                 team => <<"Navy">>}},
                     {prize_pool_refunded, [{<<"Bo">>, 3960}, {<<"Ann">>, 2640}]}],
                    lists:nthtail(1, caught_up(?CHAMPIONSHIP_FINAL, Unowned)))}].

a_team_the_league_does_not_carry_records_nothing_test() ->
    Elsewhere = with(season(), [{schedule_synced, schedule(<<"Oregon">>)}]),
    ?assertEqual([], caught_up(?FIRST_ROUND_FINAL, Elsewhere)).

season() ->
    Opened = league_state:new(
               {league_opened,
                #{settings => #{max_teams => 5, stake_units => 700,
                                house_fee_basis_points => 2000},
                  commissioner => <<"Ann">>, owners => [<<"Ann">>, <<"Bo">>],
                  teams => [<<"Utah">>, <<"Navy">>, <<"Rice">>]}}),
    with(Opened,
         [{contribution_confirmed, #{owner => <<"Ann">>, units => 20000}},
          {contribution_confirmed, #{owner => <<"Bo">>, units => 30000}},
          {team_bought, #{owner => <<"Ann">>, team => <<"Utah">>, price_units => 20000}},
          {schedule_synced, schedule(<<"Utah">>)},
          {prize_pool_frozen, 20000}]).

schedule(FirstRoundWinner) ->
    [#{week => 1, season_type => regular, home_team => <<"Rice">>,
       away_team => <<"Navy">>, kickoff => {utc, 1}, line => no_line_quoted,
       final_at => {utc, ?LAST_REGULAR_FINAL}, home_points => 0, away_points => 0},
     playoff(<<"College Football Playoff First Round Game">>, FirstRoundWinner,
             ?FIRST_ROUND_FINAL),
     playoff(<<"College Football Playoff National Championship">>, <<"Navy">>,
             ?CHAMPIONSHIP_FINAL)].

playoff(Notes, Winner, FinalAt) ->
    #{week => 1, season_type => postseason, home_team => Winner, away_team => <<"Rice">>,
      kickoff => {utc, FinalAt - 1}, line => no_line_quoted, final_at => {utc, FinalAt},
      home_points => 21, away_points => 3, notes => Notes}.

frozen_at(At) ->
    #{prize_pool := not_frozen} = Unfrozen = (season())#{prize_pool := not_frozen},
    league_playoff:frozen({utc, At}, Unfrozen).

frozen_at_again(At) ->
    league_playoff:frozen({utc, At}, with(season(), [{team_bought,
                                                      #{owner => <<"Bo">>, team => <<"Rice">>,
                                                        price_units => 100}}])).

caught_up(At, State) ->
    league_playoff:paid({utc, At}, State).

with(State, Events) ->
    lists:foldl(fun league_state:apply_event/2, State, Events).
