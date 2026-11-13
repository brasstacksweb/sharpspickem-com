-module(league_settlement_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, {utc, 5000}).

the_settlement_test_() ->
    [{"§13: each owner's whole balance paid out, the largest first",
      ?_assertEqual({ok, [{season_settled, [{<<"Bo">>, 30000}, {<<"Ann">>, 20000}]}]},
                    act(<<"Ann">>, settle_season, finished()))},
     {"the balances it pays are left at nothing",
      ?_assertEqual([], league_invariants:broken(?NOW, settled()))},
     {"by the Commissioner alone",
      ?_assertEqual({refused, not_the_commissioner},
                    act(<<"Bo">>, settle_season, finished()))},
     {"never twice",
      ?_assertEqual({refused, already_settled}, act(<<"Ann">>, settle_season, settled()))},
     {"§13: and no money comes in afterwards, with nobody left to pay it out to",
      ?_assertEqual({refused, season_settled},
                    act(<<"Ann">>, {confirm_contribution, 2, 100}, settled()))}].

an_unfinished_season_test() ->
    ?assertEqual({refused, {not_ready, [prize_pool_not_frozen,
                                        {payouts_not_recorded, 15}]}},
                 act(<<"Ann">>, settle_season, opened())).

a_balance_left_behind_breaks_the_settlement_test() ->
    #{owners := #{<<"Bo">> := Bo} = Owners} = Settled = settled(),
    ?assertEqual([held_after_the_settlement],
                 [element(1, Broken)
                  || Broken <- league_invariants:broken(
                                 ?NOW, Settled#{owners := Owners#{<<"Bo">> := Bo#{
                                                                    funds_units := 1}}}),
                     element(1, Broken) =:= held_after_the_settlement]).

opened() ->
    league_state:new({league_opened,
                      #{settings => #{max_teams => 5, stake_units => 700,
                                      house_fee_basis_points => 2000},
                        commissioner => <<"Ann">>, owners => [<<"Ann">>, <<"Bo">>],
                        teams => [<<"Utah">>]}}).

finished() ->
    with(opened(),
         [{contribution_requested, #{owner => <<"Ann">>, units => 20000}},
          {contribution_confirmed, 1, 20000},
          {contribution_requested, #{owner => <<"Bo">>, units => 30000}},
          {contribution_confirmed, 2, 30000},
          {prize_pool_frozen, 0}
          | [{playoff_share_forfeited, #{round => Round, team => <<"Utah">>}}
             || {Round, _Share, Games} <- football_playoff_payout:schedule(),
                _Game <- lists:seq(1, Games)]]).

settled() ->
    {ok, Events} = act(<<"Ann">>, settle_season, finished()),
    with(finished(), Events).

act(Actor, Command, State) ->
    league_commands:decide(#{at => ?NOW, actor => Actor, command => Command}, State).

with(State, Events) ->
    lists:foldl(fun league_state:apply_event/2, State, Events).
