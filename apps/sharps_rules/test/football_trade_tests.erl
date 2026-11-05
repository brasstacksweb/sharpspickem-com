-module(football_trade_tests).

-include_lib("eunit/include/eunit.hrl").

the_rulebooks_four_shapes_test_() ->
    [
        {"§9: Alabama for $20 is a sale, booked at the price for the buyer",
         ?_assertEqual([move(alabama, alice, bob, 1500, 2000, 2000)],
                       moves(trade(alabama, no_team, 2000)))},
        {"§9: Michigan for Notre Dame swaps the bases; neither owner realizes anything",
         ?_assertEqual([move(michigan, alice, bob, 3000, 3000, 2800),
                        move(notre_dame, bob, alice, 2800, 2800, 3000)],
                       moves(trade(michigan, notre_dame, 0)))},
        {"§9: Oregon and $5 for Penn State adds the $5 to what Alice books",
         ?_assertEqual([move(oregon, alice, bob, 2500, 2500, 3500),
                        move(penn_state, bob, alice, 4000, 4000, 3000)],
                       moves(trade(oregon, penn_state, -500)))},
        {"§9: Georgia for Clemson and $8 realizes only the $2 beyond Georgia's $6 basis",
         ?_assertEqual([move(georgia, alice, bob, 600, 800, 2000),
                        move(clemson, bob, alice, 1200, 1200, 0)],
                       moves(trade(georgia, clemson, 800)))}
    ].

proceeds_less_new_basis_is_the_cash_for_each_owner_test_() ->
    [{lists:flatten(io_lib:format("~p ~p ~p, for ~p", [FromA, FromB, CashToA, Owner])),
      ?_assertEqual(CashIn, proceeds_of(Owner, Moves) - booked_by(Owner, Moves))}
     || {FromA, FromB, CashToA} <- [{alabama, no_team, 2000}, {michigan, notre_dame, 0},
                                    {oregon, penn_state, -500}, {georgia, clemson, 800},
                                    {no_team, clemson, -1200}, {georgia, clemson, -300}],
        Moves <- [moves(trade(FromA, FromB, CashToA))],
        {Owner, CashIn} <- [{alice, CashToA}, {bob, -CashToA}]].

trades_that_are_not_trades_test_() ->
    [
        {"§9: a trade has to move a team",
         ?_assertEqual({refused, moves_no_team}, settle(trade(no_team, no_team, 500)))},
        {"§9: cash moves only against a team coming the other way",
         ?_assertEqual({refused, {paid_with_no_team_behind_it, alice}},
                       settle(trade(no_team, clemson, 500)))}
    ].

held_until_it_can_settle_test_() ->
    [
        {"nothing settles until the counterparty confirms",
         ?_assertEqual({held, waiting_for_confirmation},
                       settle((trade(alabama, no_team, 2000))#{confirmed := false}))},
        {"a team that changed hands holds the trade",
         ?_assertEqual({held, {alice, {no_longer_owns, alabama}}},
                       settle(trade(alabama, no_team, 2000),
                              #{teams => #{alabama => team(carol, 1500)}}))},
        {"§6: one game-locked team holds the whole swap, not half of it",
         ?_assertEqual({held, {not_tradable_yet, penn_state}},
                       settle(trade(oregon, penn_state, 0),
                              #{teams => #{penn_state => (team(bob, 4000))#{
                                                            tradable := false}}}))},
        {"whichever side it is on; catches checking only one owner's team",
         ?_assertEqual({held, {not_tradable_yet, oregon}},
                       settle(trade(oregon, penn_state, 0),
                              #{teams => #{oregon => (team(alice, 2500))#{
                                                        tradable := false}}}))}
    ].

each_owner_must_be_able_to_take_it_test_() ->
    [
        {"a trade cannot take an owner past the team maximum",
         ?_assertEqual({held, {bob, over_the_maximum}},
                       settle(trade(alabama, no_team, 2000),
                              #{owners => #{bob => owner(10000, 5)}}))},
        {"an even swap at the maximum is fine; catches counting only arrivals",
         ?_assertMatch({settle, _},
                       settle(trade(michigan, notre_dame, 0),
                              #{owners => #{bob => owner(10000, 5)}}))},
        {"the buyer must have the cash",
         ?_assertEqual({held, {bob, short_of_cash}},
                       settle(trade(alabama, no_team, 2000),
                              #{owners => #{bob => owner(1999, 3)}}))},
        {"§11: nor may the cash spend into the Battle reserve",
         ?_assertMatch({held, {bob, {would_spend_into_the_reserve,
                                     #{teams_after := 4, reserve_units := 2000}}}},
                       settle(trade(alabama, no_team, 2000),
                              #{owners => #{bob => owner(3999, 3)}}))},
        {"spending down to exactly the reserve settles",
         ?_assertMatch({settle, _},
                       settle(trade(alabama, no_team, 2000),
                              #{owners => #{bob => owner(4000, 3)}}))},
        {"Q21: a team arriving brings its second game into the reserve",
         ?_assertMatch({held, {bob, {would_spend_into_the_reserve,
                                     #{reserve_units := 2500}}}},
                       settle(trade(alabama, no_team, 2000),
                              #{owners => #{bob => owner(4000, 3)},
                                teams => #{alabama => (team(alice, 1500))#{
                                                         extra_games_this_week := 1}}}))}
    ].

margin_call_test_() ->
    BobShort = #{owners => #{bob => owner(1000, 3)}},
    [
        {"Q20: an owner in Margin Call cannot take on another team",
         ?_assertEqual({held, {bob, in_margin_call_and_gaining_a_team}},
                       settle(trade(alabama, no_team, 500), BobShort))},
        {"nor pay cash in an even swap, which would take them further under",
         ?_assertEqual({held, {bob, in_margin_call_and_paying_cash}},
                       settle(trade(oregon, penn_state, 300), BobShort))},
        {"an even swap with no cash is a way out, whatever it is worth",
         ?_assertMatch({settle, _}, settle(trade(michigan, notre_dame, 0), BobShort))},
        {"so is selling a team for cash; catches the reserve check closing the exit",
         ?_assertMatch({settle, _}, settle(trade(no_team, clemson, -1000), BobShort))}
    ].

proceeds_of(Owner, Moves) ->
    lists:sum([Proceeds || #{from := From, proceeds_units := Proceeds} <- Moves,
                           From =:= Owner]).

booked_by(Owner, Moves) ->
    lists:sum([NewBasis || #{to := To, new_basis_units := NewBasis} <- Moves,
                           To =:= Owner]).

moves(Trade) ->
    {settle, #{moves := Moves}} = settle(Trade),
    Moves.

settle(Trade) ->
    settle(Trade, #{}).

settle(Trade, #{} = Changes) ->
    football_trade:decide(Trade, league(Changes)).

trade(TeamFromAlice, TeamFromBob, CashToAlice) ->
    #{owner_a => alice, owner_b => bob,
      team_from_a => TeamFromAlice, team_from_b => TeamFromBob,
      cash_to_a_units => CashToAlice, confirmed => true}.

league(Changes) ->
    Teams = #{alabama => team(alice, 1500), michigan => team(alice, 3000),
              oregon => team(alice, 2500), georgia => team(alice, 600),
              notre_dame => team(bob, 2800), penn_state => team(bob, 4000),
              clemson => team(bob, 1200)},
    Owners = #{alice => owner(10000, 4), bob => owner(10000, 3)},
    #{teams => maps:merge(Teams, maps:get(teams, Changes, #{})),
      owners => maps:merge(Owners, maps:get(owners, Changes, #{})),
      max_teams => 5,
      stake_units => 500,
      battle_season => battles_being_created}.

team(Owner, Basis) ->
    #{owner => Owner, tradable => true, basis_units => Basis, extra_games_this_week => 0}.

owner(Funds, TeamsHeld) ->
    #{funds_units => Funds, escrow_units => 0, teams_held => TeamsHeld,
      extra_games_this_week => 0}.

move(Team, From, To, Basis, Proceeds, NewBasis) ->
    #{team => Team, from => From, to => To, basis_units => Basis,
      proceeds_units => Proceeds, new_basis_units => NewBasis}.
