-module(football_market_order_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SHORT_OF_A_RESERVE_OF(Units),
        {refused, {would_spend_into_the_reserve, #{reserve_units := Units}}}).

the_market_is_open_only_while_the_season_runs_test_() ->
    [
        {"§6: once the Championship Game ends the market closes",
         ?_assertEqual({refused, season_over}, order({bid, 1800}, #{season => over}))},
        {"and it opens once the draft is complete",
         ?_assertEqual({refused, {market_opens_after_the_draft, drafting}},
                       order({bid, 1800}, #{season => drafting}))},
        {"an available team is acted on now",
         ?_assertEqual(execute, order({bid, 1800}))},
        {"§6: an unavailable one queues to the next opening, saying why",
         ?_assertEqual({queue, unpriced},
                       order({bid, 1800}, #{team => #{available => {no, unpriced}}}))}
    ].

refused_whatever_the_team_test_() ->
    [
        {"one order per team per window",
         ?_assertEqual({refused, already_ordered_this_window},
                       order({bid, 1800}, #{team => #{has_your_order => true}}))},
        {"§9: a team promised in a pending trade is spoken for",
         ?_assertEqual({refused, in_pending_trade},
                       order(drop, #{team => yours(#{in_pending_trade => true})}))}
    ].

margin_call_test_() ->
    Short = #{you => #{funds_units => 1000}},
    [
        {"Q20: an owner in Margin Call cannot bid",
         ?_assertEqual({refused, in_margin_call}, order({bid, 1800}, Short))},
        {"nor add a free team",
         ?_assertEqual({refused, in_margin_call},
                       order(add, Short#{team => unranked()}))},
        {"but may drop, one of the ways out",
         ?_assertEqual(execute, order(drop, Short#{team => yours(#{})}))},
        {"or sell to the House",
         ?_assertEqual(execute, order(sale, Short#{team => yours(#{})}))}
    ].

bids_test_() ->
    [
        {"§7: a bid at Market Value is valid",
         ?_assertEqual(execute, order({bid, 1800}))},
        {"§7: a bid below Market Value is rejected",
         ?_assertEqual({refused, {below_market_value, 1800}}, order({bid, 1799}))},
        {"an unranked team is added free, not bid on",
         ?_assertEqual({refused, unranked_so_add_it_free},
                       order({bid, 1800}, #{team => unranked()}))},
        {"you cannot bid on your own team",
         ?_assertEqual({refused, you_already_own_it},
                       order({bid, 1800}, #{team => yours(#{})}))},
        {"bidding is for House teams",
         ?_assertEqual({refused, owned_by_another_owner},
                       order({bid, 1800}, #{team => #{owner => bob}}))},
        {"at the maximum, an available team has no queue to make room in",
         ?_assertEqual({refused, at_the_maximum_with_nothing_queued_to_make_room},
                       order({bid, 1800}, #{you => #{teams_held => 5}}))},
        {"Q25: a queued bid is not capped, since a queued drop may free the slot",
         ?_assertEqual({queue, kickoff_imminent},
                       order({bid, 1800},
                             #{you => #{teams_held => 5},
                               team => #{available => {no, kickoff_imminent}}}))}
    ].

a_bid_and_the_battle_reserve_test_() ->
    [
        {"§11: a bid that leaves a stake for every team it would make is fine",
         ?_assertEqual(execute, order({bid, 2000}, #{you => #{funds_units => 4000}}))},
        {"one that spends into the reserve is refused",
         ?_assertMatch({refused, {would_spend_into_the_reserve, #{reserve_units := 2000,
                                                                  headroom_units := -1}}},
                       order({bid, 2001}, #{you => #{funds_units => 4000}}))},
        {"other open bids are already spoken for",
         ?_assertMatch({refused, {would_spend_into_the_reserve, _}},
                       order({bid, 1800}, #{you => #{funds_units => 4000,
                                                     committed_to_bids_units => 201}}))},
        {"and every team they could win needs its stake too",
         ?_assertMatch(?SHORT_OF_A_RESERVE_OF(2500),
                       order({bid, 1800}, #{you => #{funds_units => 4000,
                                                     teams_pending => 1}}))},
        {"Q21: as does the team's own second game",
         ?_assertMatch(?SHORT_OF_A_RESERVE_OF(2500),
                       order({bid, 1800}, #{you => #{funds_units => 4000},
                                            team => #{extra_games_this_week => 1}}))}
    ].

free_adds_test_() ->
    [
        {"§7: an unranked House team is added free",
         ?_assertEqual(execute, order(add, #{team => unranked()}))},
        {"a ranked one is bid for",
         ?_assertEqual({refused, ranked_so_bid_for_it}, order(add))},
        {"the team is free, but holding it needs a Battle stake",
         ?_assertMatch(?SHORT_OF_A_RESERVE_OF(2000),
                       order(add, #{team => unranked(), you => #{funds_units => 1999}}))},
        {"covering that stake exactly is enough",
         ?_assertEqual(execute,
                       order(add, #{team => unranked(), you => #{funds_units => 2000}}))}
    ].

drops_and_sales_test_() ->
    [
        {"you can only drop your own team",
         ?_assertEqual({refused, not_your_team}, order(drop))},
        {"or sell it",
         ?_assertEqual({refused, not_your_team}, order(sale))},
        {"§8: once the House buys only the top 12, the 13th team cannot be sold",
         ?_assertEqual({refused, {ranked_outside_the_top_12, 13}},
                       order(sale, #{team => yours(#{rank => {ranked, 13}}),
                                     buyback_stage => buys_the_top_12}))},
        {"§8: after the second date nothing can",
         ?_assertEqual({refused, house_stopped_buying},
                       order(sale, #{team => yours(#{}),
                                     buyback_stage => buys_nothing}))},
        {"§8: an unranked team is dropped, not sold",
         ?_assertEqual({refused, unranked},
                       order(sale, #{team => yours(#{rank => unranked})}))},
        {"§8: a conditional drop always queues, even for an available team",
         ?_assertEqual({queue, held_against_its_acquisition},
                       order(conditional_drop, #{team => yours(#{})}))}
    ].

making_room_in_the_same_breath_test_() ->
    AtTheMaximum = #{you => #{teams_held => 5, funds_units => 10000}},
    Purdue = droppable(#{}),
    [
        {"§8: at the maximum, a bid can give up a team in the same breath",
         ?_assertEqual(execute, order({bid, 1800}, AtTheMaximum, Purdue))},
        {"not when it queues: a conditional drop gives the team up only if the bid wins",
         ?_assertEqual({refused, queued_so_file_a_conditional_drop},
                       order({bid, 1800},
                             AtTheMaximum#{team => #{available => {no, unpriced}}},
                             Purdue))},
        {"only an acquisition makes room for itself",
         ?_assertEqual({refused, only_an_acquisition_makes_room},
                       order(sale, AtTheMaximum#{team => yours(#{})}, Purdue))},
        {"the team given up must be yours",
         ?_assertEqual({refused, you_do_not_hold_the_team_to_drop},
                       order({bid, 1800}, AtTheMaximum, droppable(#{owner => bob})))},
        {"and not the team being acquired",
         ?_assertEqual({refused, cannot_drop_the_team_being_acquired},
                       order({bid, 1800}, AtTheMaximum,
                             droppable(#{team => notre_dame})))},
        {"nor one promised in a pending trade",
         ?_assertEqual({refused, team_to_drop_is_in_pending_trade},
                       order({bid, 1800}, AtTheMaximum,
                             droppable(#{in_pending_trade => true})))},
        {"nor one with an order of its own",
         ?_assertEqual({refused, team_to_drop_already_has_an_order},
                       order({bid, 1800}, AtTheMaximum,
                             droppable(#{has_your_order => true})))},
        {"nor one off the board",
         ?_assertEqual({refused, team_to_drop_is_off_the_board},
                       order({bid, 1800}, AtTheMaximum,
                             droppable(#{available => {no, in_game}})))},
        {"the reserve is measured on the roster the order leaves behind",
         ?_assertMatch(?SHORT_OF_A_RESERVE_OF(2500),
                       order({bid, 1800},
                             #{you => #{teams_held => 5, funds_units => 4299}},
                             Purdue))},
        {"which the dropped team's second game no longer counts toward",
         ?_assertEqual(execute,
                       order({bid, 1800},
                             #{you => #{teams_held => 5, funds_units => 4300,
                                        extra_games_this_week => 1}},
                             droppable(#{extra_games_this_week => 1})))}
    ].

order(Kind) ->
    order(Kind, #{}).

order(Kind, Changes) ->
    decide(#{kind => Kind, making_room => no}, Changes).

order(Kind, Changes, Drop) ->
    decide(#{kind => Kind, making_room => {by_dropping, Drop}}, Changes).

decide(Order, Changes) ->
    You = #{owner => alice, funds_units => 10000, escrow_units => 0, teams_held => 3,
            extra_games_this_week => 0, committed_to_bids_units => 0, teams_pending => 0},
    NotreDame = #{team => notre_dame, owner => house, rank => {ranked, 9},
                  market_value_units => 1800, extra_games_this_week => 0,
                  available => yes, in_pending_trade => false, has_your_order => false},
    football_market_order:decide(
        Order,
        #{season => maps:get(season, Changes, running),
          you => maps:merge(You, maps:get(you, Changes, #{})),
          team => maps:merge(NotreDame, maps:get(team, Changes, #{})),
          buyback_stage => maps:get(buyback_stage, Changes, buys_the_top_25),
          max_teams => 5,
          stake_units => 500,
          battle_season => battles_being_created}).

yours(Changes) ->
    maps:merge(#{owner => alice}, Changes).

unranked() ->
    #{rank => unranked, market_value_units => 0}.

droppable(Changes) ->
    maps:merge(#{team => purdue, owner => alice, available => yes,
                 in_pending_trade => false, has_your_order => false,
                 proceeds_units => 0, extra_games_this_week => 0},
               Changes).
