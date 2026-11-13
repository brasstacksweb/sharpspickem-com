-module(football_draft_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ORDER, [<<"Ann">>, <<"Bo">>, <<"Cy">>]).

the_snake_test_() ->
    [
        {"§5: round 1 runs first to last",
         ?_assertEqual(?ORDER, in_round(1))},
        {"§5: round 2 runs last to first; catches a draft that never reverses",
         ?_assertEqual(lists:reverse(?ORDER), in_round(2))},
        {"the last pick of a round is followed by the first of the next",
         ?_assertEqual({picking, {2, 1}}, next({1, 3}, #{}))},
        {"an owner with a full roster is skipped; catches waiting on them",
         ?_assertEqual({picking, {1, 3}}, next({1, 1}, #{<<"Bo">> => 2}))},
        {"the draft ends after the last round; catches a round too many",
         ?_assertEqual(complete, next({2, 3}, #{}))},
        {"and ends early once every roster is full",
         ?_assertEqual(complete, next({1, 1}, #{<<"Ann">> => 2, <<"Bo">> => 2,
                                                <<"Cy">> => 2}))}
    ].

setting_up_test_() ->
    Setup = draft(setup),
    [
        {"only the Commissioner creates a draft",
         ?_assertEqual({refused, not_the_commissioner},
                       football_draft:create(owner(), no_draft))},
        {"one draft at a time",
         ?_assertEqual({refused, a_draft_already_exists},
                       football_draft:create(commissioner(), Setup))},
        {"the order must name every owner; catches dropping one",
         ?_assertEqual({refused, every_owner_exactly_once},
                       set_order([<<"Ann">>, <<"Bo">>]))},
        {"a name repeated is kept once",
         ?_assertEqual({order_set, [<<"Cy">>, <<"Ann">>, <<"Bo">>]},
                       set_order([<<"Cy">>, <<"Ann">>, <<"Cy">>, <<"Bo">>]))},
        {"§8: the House's two dates must be set before the first pick",
         ?_assertEqual({refused, set_the_buyback_dates_first}, start(Setup, not_set))},
        {"a draft in progress cannot be started again",
         ?_assertEqual({refused, no_draft_waiting}, start(draft({1, 1}), set))}
    ].

picking_test_() ->
    [
        {"the owner on the clock picks for themselves",
         ?_assertMatch({drafted, #{owner := <<"Ann">>, team := <<"Utah">>, round := 1}},
                       select(#{owner => <<"Ann">>, commissioner => false}, #{}))},
        {"the Commissioner picks for whoever is on the clock, never for themselves",
         ?_assertMatch({drafted, #{owner := <<"Ann">>}}, select(commissioner(), #{}))},
        {"anyone else is told it is not their turn",
         ?_assertEqual({refused, not_your_turn}, select(owner(), #{}))},
        {"a team already drafted is gone",
         ?_assertEqual({refused, already_taken},
                       select(commissioner(), #{team => #{team => <<"Utah">>,
                                                          owner => <<"Bo">>,
                                                          price_units => 0}}))},
        {"a full roster cannot pick",
         ?_assertEqual({refused, at_the_maximum},
                       select(commissioner(),
                              #{rosters => #{teams_held => #{<<"Ann">> => 2},
                                             max_teams => 2}}))},
        {"§11: the reserve binds from the first pick; catches checking only the price",
         ?_assertMatch({refused, {would_spend_into_the_reserve, _}},
                       select(commissioner(), #{holding => holding(1500)}))},
        {"a pick that leaves exactly the reserve is fine; catches > for >=",
         ?_assertMatch({drafted, _}, select(commissioner(), #{holding => holding(1700)}))}
    ].

passing_test_() ->
    Rosters = #{teams_held => #{}, max_teams => 2},
    [
        {"a pass moves the clock on",
         ?_assertEqual({passed, <<"Ann">>, {picking, {1, 2}}},
                       football_draft:pass(commissioner(), draft({1, 1}), Rosters))},
        {"§5: once every owner with room has passed, the draft is over",
         ?_assertEqual({passed, <<"Cy">>, complete},
                       football_draft:pass(commissioner(),
                                           passed({1, 3}, [<<"Ann">>, <<"Bo">>]),
                                           Rosters))},
        {"an owner with a full roster need not pass; catches waiting on them",
         ?_assertEqual({passed, <<"Cy">>, complete},
                       football_draft:pass(commissioner(), passed({1, 3}, [<<"Ann">>]),
                                           Rosters#{teams_held := #{<<"Bo">> => 2}}))}
    ].

undoing_test_() ->
    Pick = #{owner => <<"Ann">>, team => <<"Utah">>, price_units => 100, round => 2},
    Picked = (draft(complete))#{picks := [Pick]},
    [
        {"the last pick goes back to the slot it was made in, in a reversed round",
         ?_assertEqual({undone, Pick, {2, 3}}, undo(commissioner(), Picked))},
        {"only the Commissioner undoes a pick",
         ?_assertEqual({refused, not_the_commissioner}, undo(owner(), Picked))},
        {"nothing to undo before the first pick",
         ?_assertEqual({refused, no_picks_to_undo}, undo(commissioner(), draft({1, 1})))}
    ].

undo(Actor, Draft) ->
    football_draft:undo(Actor, Draft).

in_round(Round) ->
    [football_draft:owner_at(?ORDER, {Round, Position}) || Position <- [1, 2, 3]].

next(Slot, TeamsHeld) ->
    football_draft:next(draft(Slot), Slot, #{teams_held => TeamsHeld, max_teams => 2}).

set_order(Order) ->
    football_draft:set_order(commissioner(), draft(setup), Order).

start(Draft, Dates) ->
    football_draft:start(commissioner(), #{draft => Draft, buyback_dates => Dates}).

select(Actor, Overrides) ->
    football_draft:select(Actor, maps:merge(
        #{draft => draft({1, 1}),
          team => #{team => <<"Utah">>, owner => house, price_units => 1500},
          rosters => #{teams_held => #{}, max_teams => 2},
          holding => holding(100000)}, Overrides)).

holding(Funds) ->
    #{funds_units => Funds, cash_out_units => 0, escrow_units => 0, teams_held => 0,
      teams_gained => 1, max_teams => 2, extra_games_this_week => 0, stake_units => 200,
      battle_season => battles_being_created}.

passed(Slot, Owners) ->
    (draft(Slot))#{passed := Owners}.

draft(Stage) ->
    #{order => ?ORDER, stage => stage(Stage), passed => [], picks => []}.

stage(setup) -> setup;
stage(complete) -> complete;
stage(Slot) -> {picking, Slot}.

commissioner() -> #{owner => <<"Ann">>, commissioner => true}.

owner() -> #{owner => <<"Bo">>, commissioner => false}.
