-module(league_opening_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, {utc, 1000000}).

-define(KICKOFF, {utc, 2000000}).

equal_bids_test_() ->
    State = league([{<<"Ann">>, 10000}, {<<"Bo">>, 10000}], #{},
                   [{poll_applied, #{week => 1, poll => ap, ranks => #{<<"Utah">> => 20}}},
                    queued(1, <<"Ann">>, bid, <<"Utah">>),
                    queued(2, <<"Bo">>, bid, <<"Utah">>)]),
    [{"§7: two equal bids go to the one queued first; catches the league passing "
      "the auction a queue time that ties to the later bid",
      ?_assertEqual([<<"Ann">>], bought(settled(State)))}].

freed_games_test_() ->
    Holding = league([{<<"Ann">>, 1400}], #{max_teams => 2},
                     [{schedule_synced, [game(<<"Utah">>, <<"Rice">>),
                                         game(<<"Utah">>, <<"Army">>),
                                         game(<<"Ohio State">>, <<"Rice">>),
                                         game(<<"Ohio State">>, <<"Army">>)]},
                      {team_added, #{owner => <<"Ann">>, team => <<"Utah">>}},
                      {team_added, #{owner => <<"Ann">>, team => <<"Ohio State">>}},
                      queued(1, <<"Ann">>, conditional_drop, <<"Utah">>),
                      queued(2, <<"Ann">>, add, <<"Navy">>)]),
    [{"§11: an add that makes room by a conditional drop takes the dropped team's "
      "extra games off the owner's count, as the PHP does; catches the freed games "
      "not being counted",
      ?_assertEqual([<<"Navy">>], added(settled(Holding)))},
     {"and a unit short of that reserve still refuses the add",
      ?_assertEqual([], added(settled(funded(<<"Ann">>, -1, Holding))))}].

league(Owners, Settings, Events) ->
    Names = [Owner || {Owner, _Funds} <- Owners],
    Opened = league_state:new(
               {league_opened,
                #{settings => maps:merge(#{max_teams => 5, stake_units => 700,
                                           house_fee_basis_points => 2000}, Settings),
                  commissioner => hd(Names), owners => Names,
                  teams => [<<"Utah">>, <<"Ohio State">>, <<"Navy">>, <<"Rice">>,
                            <<"Army">>]}}),
    Funded = lists:foldl(fun({Owner, Funds}, State) -> funded(Owner, Funds, State) end,
                         Opened, Owners),
    lists:foldl(fun league_state:apply_event/2, Funded, Events).

funded(Owner, Units, State) ->
    league_state:apply_event({contribution_confirmed, #{owner => Owner, units => Units}},
                             State).

queued(Number, Owner, conditional_drop, Team) ->
    {order_queued, Order} = queued(Number, Owner, drop, Team),
    {order_queued, Order#{conditional := true}};
queued(Number, Owner, Kind, Team) ->
    {order_queued, #{number => Number, owner => Owner, team => Team, kind => Kind,
                     amount_units => amount(Kind), conditional => false, priority => 1}}.

amount(bid) -> 900;
amount(_Free) -> none.

game(Home, Away) ->
    #{week => 1, season_type => regular, home_team => Home, away_team => Away,
      kickoff => ?KICKOFF, line => no_line_quoted, final_at => {utc, 2012600},
      home_points => 0, away_points => 0}.

settled(State) ->
    league_opening:settle(#{at => ?NOW, priced => false}, ?NOW, State).

bought(Events) ->
    [Owner || {team_bought, #{owner := Owner}} <- Events].

added(Events) ->
    [Team || {team_added, #{team := Team}} <- Events].
