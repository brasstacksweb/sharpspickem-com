-module(football_blind_auction_tests).

-include_lib("eunit/include/eunit.hrl").

the_rulebook_example_test() ->
    Spencer = bid(1, spencer, 1800),
    Mike = bid(2, mike, 2000),
    Sarah = bid(3, sarah, 2300),
    Chris = bid(4, chris, 1900),
    ?assertEqual([{won, notre_dame, Sarah, no_drop}],
                 resolve([lot(notre_dame, [Spencer, Mike, Sarah, Chris])])).

identical_bids_go_to_whoever_queued_first_test_() ->
    Earlier = (bid(1, mike, 2000))#{queued_at := {utc, 1000}},
    Later = (bid(2, sarah, 2000))#{queued_at := {utc, 1001}},
    [
        {"§7: the earlier of two identical highest bids wins",
         ?_assertEqual([{won, notre_dame, Earlier, no_drop}],
                       resolve([lot(notre_dame, [Later, Earlier])]))},
        {"whatever order the bids arrive in",
         ?_assertEqual([{won, notre_dame, Earlier, no_drop}],
                       resolve([lot(notre_dame, [Earlier, Later])]))}
    ].

a_team_the_house_no_longer_owns_is_skipped_test() ->
    ?assertEqual([{skipped, notre_dame, no_longer_a_house_team}],
                 resolve([(lot(notre_dame, [bid(1, mike, 2000)]))#{
                               house_owned := false}])).

a_void_bid_passes_the_team_to_the_next_highest_test() ->
    Sarah = bid(1, sarah, 2300),
    Mike = bid(2, mike, 2000),
    ?assertEqual([{void, notre_dame, Sarah, insufficient_funds},
                  {won, notre_dame, Mike, no_drop}],
                 resolve([lot(notre_dame, [Sarah, Mike])],
                         #{owners => #{sarah => owner(2299, 2)}})).

ranking_your_bids_test_() ->
    SarahOnOregon = (bid(1, sarah, 3000))#{priority := 1},
    SarahOnNotreDame = (bid(2, sarah, 2300))#{priority := 2},
    MikeOnNotreDame = bid(3, mike, 2000),
    Lots = [lot(notre_dame, [SarahOnNotreDame, MikeOnNotreDame]),
            lot(oregon, [SarahOnOregon])],
    OneSlotLeft = #{owners => #{sarah => owner(10000, 4)}},
    [
        {"§7: with room for one, the owner keeps the bid they ranked first",
         ?_assertMatch([_, _, {won, oregon, SarahOnOregon, no_drop}],
                       resolve(Lots, OneSlotLeft))},
        {"§7: the bid given up is void, and the next-highest bidder inherits the team",
         ?_assertMatch([{void, notre_dame, SarahOnNotreDame,
                         over_the_maximum_with_no_drop},
                        {won, notre_dame, MikeOnNotreDame, no_drop} | _],
                       resolve(Lots, OneSlotLeft))},
        {"ranked the other way, the other team is kept; catches ignoring the ranking",
         ?_assertMatch([{won, notre_dame, _, no_drop},
                        {void, oregon, _, over_the_maximum_with_no_drop}],
                       resolve(Lots, #{owners => #{sarah => owner(10000, 4)},
                                       priorities => #{1 => 2, 2 => 1}}))}
    ].

a_released_team_can_fill_its_next_bidder_too_test() ->
    SarahOnNotreDame = (bid(1, sarah, 2300))#{priority := 2},
    SarahOnOregon = (bid(2, sarah, 3000))#{priority := 1},
    MikeOnNotreDame = (bid(3, mike, 2000))#{priority := 2},
    MikeOnClemson = (bid(4, mike, 1500))#{priority := 1},
    ChrisOnNotreDame = bid(5, chris, 1900),
    ?assertEqual([{void, notre_dame, SarahOnNotreDame, over_the_maximum_with_no_drop},
                  {void, notre_dame, MikeOnNotreDame, over_the_maximum_with_no_drop},
                  {won, notre_dame, ChrisOnNotreDame, no_drop},
                  {won, oregon, SarahOnOregon, no_drop},
                  {won, clemson, MikeOnClemson, no_drop}],
                 resolve([lot(notre_dame, [SarahOnNotreDame, MikeOnNotreDame,
                                           ChrisOnNotreDame]),
                          lot(oregon, [SarahOnOregon]),
                          lot(clemson, [MikeOnClemson])],
                         #{owners => #{sarah => owner(10000, 4),
                                       mike => owner(10000, 4)}})).

drops_test_() ->
    AtTheMaximum = #{owners => #{sarah => owner(10000, 5)},
                     drops => #{sarah => [drop_purdue]}},
    TooDear = (bid(1, sarah, 20000))#{priority := 1},
    Affordable = (bid(2, sarah, 2000))#{priority := 2},
    [
        {"an owner at the maximum wins by the drop they queued",
         ?_assertEqual([{won, notre_dame, Affordable, {dropping, drop_purdue}}],
                       resolve([lot(notre_dame, [Affordable])], AtTheMaximum))},
        {"one drop makes room for one win",
         ?_assertMatch([{won, notre_dame, _, {dropping, drop_purdue}},
                        {void, oregon, _, over_the_maximum_with_no_drop}],
                       resolve([lot(notre_dame, [(bid(1, sarah, 2000))#{priority := 1}]),
                                lot(oregon, [(bid(2, sarah, 2000))#{priority := 2}])],
                               AtTheMaximum))},
        {"a drop is spent only on a bid that wins; catches spending it on a void bid",
         ?_assertMatch([{void, oregon, TooDear, insufficient_funds},
                        {won, notre_dame, Affordable, {dropping, drop_purdue}}],
                       resolve([lot(oregon, [TooDear]), lot(notre_dame, [Affordable])],
                               AtTheMaximum))}
    ].

the_money_spent_on_one_win_is_gone_for_the_next_test() ->
    First = (bid(1, sarah, 3000))#{priority := 1},
    Second = (bid(2, sarah, 2500))#{priority := 2},
    ?assertMatch([{won, notre_dame, First, no_drop},
                  {void, oregon, Second, insufficient_funds}],
                 resolve([lot(notre_dame, [First]), lot(oregon, [Second])],
                         #{owners => #{sarah => owner(5000, 2)}})).

a_team_the_house_no_longer_owns_takes_no_room_test() ->
    OnTheSoldTeam = (bid(1, sarah, 2000))#{priority := 1},
    OnTheHouseTeam = (bid(2, sarah, 2000))#{priority := 2},
    ?assertMatch([{skipped, oregon, _}, {won, notre_dame, OnTheHouseTeam, no_drop}],
                 resolve([(lot(oregon, [OnTheSoldTeam]))#{house_owned := false},
                          lot(notre_dame, [OnTheHouseTeam])],
                         #{owners => #{sarah => owner(10000, 4)}})).

the_battle_reserve_test_() ->
    Bid = bid(1, sarah, 1500),
    [
        {"§11: a win must leave a stake for every team then held",
         ?_assertMatch([{void, notre_dame, Bid, {would_spend_into_the_reserve,
                                                 #{reserve_units := 2000}}}],
                       resolve([lot(notre_dame, [Bid])],
                               #{owners => #{sarah => owner(3499, 3)}}))},
        {"leaving exactly the reserve wins",
         ?_assertMatch([{won, notre_dame, Bid, no_drop}],
                       resolve([lot(notre_dame, [Bid])],
                               #{owners => #{sarah => owner(3500, 3)}}))},
        {"Q21: a team playing twice this week needs its second stake",
         ?_assertMatch([{void, notre_dame, Bid, {would_spend_into_the_reserve,
                                                 #{reserve_units := 2500}}}],
                       resolve([(lot(notre_dame, [Bid]))#{extra_games_this_week := 1}],
                               #{owners => #{sarah => owner(3500, 3)}}))}
    ].

the_report_follows_the_lots_order_test() ->
    ?assertMatch([{won, clemson, _, _}, {skipped, oregon, _}, {won, notre_dame, _, _}],
                 resolve([lot(clemson, [bid(1, mike, 1500)]),
                          (lot(oregon, []))#{house_owned := false},
                          lot(notre_dame, [bid(2, sarah, 2000)])])).

resolve(Lots) ->
    resolve(Lots, #{}).

resolve(Lots, Changes) ->
    Priorities = maps:get(priorities, Changes, #{}),
    Reranked = fun(#{priority := Priority} = Bid) ->
                       Bid#{priority := maps:get(Priority, Priorities, Priority)}
               end,
    Reprioritized = [Lot#{bids := lists:map(Reranked, Bids)}
                     || #{bids := Bids} = Lot <- Lots],
    Owners = #{spencer => owner(10000, 2), mike => owner(10000, 2),
               sarah => owner(10000, 2), chris => owner(10000, 2)},
    football_blind_auction:resolve(
        #{lots => Reprioritized,
          owners => maps:merge(Owners, maps:get(owners, Changes, #{})),
          drops => maps:get(drops, Changes, #{}),
          max_teams => 5,
          stake_units => 500,
          battle_season => battles_being_created}).

lot(Team, Bids) ->
    #{team => Team, house_owned => true, extra_games_this_week => 0, bids => Bids}.

bid(Id, Owner, Amount) ->
    #{bid => Id, owner => Owner, amount_units => Amount, queued_at => {utc, Id},
      priority => 1}.

owner(Funds, TeamsHeld) ->
    #{funds_units => Funds, escrow_units => 0, teams_held => TeamsHeld,
      extra_games_this_week => 0}.
