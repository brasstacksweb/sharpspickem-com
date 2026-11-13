-module(league_close_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CHAMPIONSHIP_FINAL, {utc, 3000000}).

-define(BEFORE_THE_FINAL, {utc, 2999999}).

the_close_test_() ->
    [{"§6: the Championship Game final expires every unsettled order and trade",
      ?_assertEqual([{order_expired, 1}, {trade_expired, 1}],
                    expired(?CHAMPIONSHIP_FINAL, left_open()))},
     {"and not a second sooner; catches expiring them before the season is over",
      ?_assertEqual([], expired(?BEFORE_THE_FINAL, left_open()))},
     {"and once only; catches an expiry that leaves the order or trade pending",
      ?_assertEqual([], expired(?CHAMPIONSHIP_FINAL, closed()))}].

after_the_close_test_() ->
    [{"the expired trade cannot be confirmed; catches a trade left pending at the close",
      ?_assertEqual({refused, no_such_trade}, act(<<"Bo">>, {confirm_trade, 1}))},
     {"or cancelled",
      ?_assertEqual({refused, no_such_trade}, act(<<"Ann">>, {cancel_trade, 1}))},
     {"the expired bid cannot be reordered; catches an order left pending at the close",
      ?_assertEqual({refused, not_your_pending_bid}, act(<<"Ann">>, {reorder_bid, 1, up}))},
     {"and cancelling it does nothing",
      ?_assertEqual({ok, []}, act(<<"Ann">>, {cancel_order, 1}))}].

left_open() ->
    Opened = league_state:new(
               {league_opened,
                #{settings => #{max_teams => 5, stake_units => 700,
                                house_fee_basis_points => 2000},
                  commissioner => <<"Ann">>, owners => [<<"Ann">>, <<"Bo">>],
                  teams => [<<"Utah">>, <<"Navy">>, <<"Rice">>]}}),
    with(Opened,
         [{contribution_requested, #{owner => <<"Ann">>, units => 10000}},
          {contribution_confirmed, 1, 10000},
          {schedule_synced, [game(regular, {utc, 1000000}),
                             game(postseason, ?CHAMPIONSHIP_FINAL)]},
          {team_added, #{owner => <<"Ann">>, team => <<"Utah">>}},
          {order_queued, #{number => 1, owner => <<"Ann">>, team => <<"Navy">>, kind => bid,
                           amount_units => 900, conditional => false, priority => 1}},
          {trade_proposed, #{number => 1, owner_a => <<"Ann">>, owner_b => <<"Bo">>,
                             team_from_a => <<"Utah">>, team_from_b => no_team,
                             cash_to_a_units => 0, confirmed => false}}]).

expired(Now, State) ->
    [Event || Event <- league_catch_up:catch_up(Now, State),
              element(1, Event) =:= order_expired orelse element(1, Event) =:= trade_expired].

closed() ->
    with(left_open(), league_catch_up:catch_up(?CHAMPIONSHIP_FINAL, left_open())).

act(Actor, Command) ->
    league_commands:decide(#{at => ?CHAMPIONSHIP_FINAL, actor => Actor, command => Command},
                           closed()).

game(SeasonType, FinalAt) ->
    #{week => 1, season_type => SeasonType, home_team => <<"Utah">>,
      away_team => <<"Rice">>, kickoff => {utc, 1}, line => no_line_quoted,
      final_at => FinalAt, home_points => 0, away_points => 0}.

with(State, Events) ->
    lists:foldl(fun league_state:apply_event/2, State, Events).
