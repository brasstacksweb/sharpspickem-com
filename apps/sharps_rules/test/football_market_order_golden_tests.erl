-module(football_market_order_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_order_goes_in_as_the_php_let_it_test() ->
    ?assertEqual([], golden:disagreements("decide_market_order", fun port/1, fun php/2)).

port(#{<<"order">> := Order, <<"snapshot">> := Snapshot}) ->
    only_the_figures_the_php_prints(
        football_market_order:decide(order(Order, Snapshot), snapshot(Snapshot))).

order(#{<<"kind">> := Kind, <<"conditional">> := Conditional, <<"amount">> := Amount},
      #{<<"drop_team">> := DropTeam} = Snapshot) ->
    #{kind => kind(Kind, Conditional, Amount),
      making_room => making_room(DropTeam, Snapshot)}.

kind(<<"bid">>, false, Amount) -> {bid, Amount};
kind(<<"add">>, false, _Amount) -> add;
kind(<<"drop">>, false, _Amount) -> drop;
kind(<<"drop">>, true, _Amount) -> conditional_drop;
kind(<<"sale">>, false, _Amount) -> sale.

making_room(null, _Snapshot) ->
    no;
making_room(#{<<"id">> := Team, <<"owner_id">> := Owner},
            #{<<"drop_in_trade">> := InTrade, <<"drop_has_order">> := HasOrder,
              <<"drop_available">> := Available, <<"drop_proceeds">> := Proceeds,
              <<"drop_extra_games">> := ExtraGames}) ->
    {by_dropping, #{team => Team, owner => Owner, available => available(Available),
                    in_pending_trade => InTrade, has_your_order => HasOrder,
                    proceeds_units => Proceeds, extra_games_this_week => ExtraGames}}.

available(true) -> yes;
available(false) -> {no, unpriced}.

snapshot(#{<<"season_over">> := SeasonOver, <<"phase">> := Phase,
           <<"team">> := #{<<"id">> := Team, <<"owner_id">> := TeamOwner},
           <<"owner_id">> := You, <<"has_order_for_team">> := HasOrder,
           <<"in_pending_trade">> := InTrade, <<"unavailable_why">> := Why,
           <<"teams_held">> := TeamsHeld, <<"funds">> := Funds, <<"escrow">> := Escrow,
           <<"extra_games">> := ExtraGames, <<"max_teams">> := MaxTeams,
           <<"rank_pos">> := Position, <<"mv">> := MarketValue,
           <<"buyback_stage">> := Stage, <<"pending_gains">> := TeamsPending,
           <<"committed_cents">> := Committed, <<"stake">> := Stake,
           <<"team_extra_games">> := TeamExtraGames,
           <<"battles_possible">> := BattlesPossible} = Snapshot) ->
    #{season => season(SeasonOver, Phase),
      you => #{owner => You, funds_units => Funds, escrow_units => Escrow,
               teams_held => TeamsHeld, extra_games_this_week => ExtraGames,
               committed_to_bids_units => Committed, teams_pending => TeamsPending},
      team => #{team => Team, owner => owner(TeamOwner), rank => rank(Position),
                market_value_units => MarketValue,
                extra_games_this_week => TeamExtraGames,
                available => availability(maps:get(<<"locked">>, Snapshot), Why),
                in_pending_trade => InTrade, has_your_order => HasOrder},
      buyback_stage => stage(Stage), max_teams => MaxTeams, stake_units => Stake,
      battle_season => battle_season(BattlesPossible)}.

season(true, _Phase) -> over;
season(false, <<"regular">>) -> running;
season(false, <<"draft">>) -> drafting;
season(false, _Setup) -> before_the_draft.

owner(null) -> house;
owner(Owner) -> Owner.

rank(null) -> unranked;
rank(Position) -> {ranked, Position}.

availability(false, null) -> yes;
availability(true, Why) -> {no, reason(Why)}.

stage(<<"open">>) -> buys_the_top_25;
stage(<<"top12">>) -> buys_the_top_12;
stage(<<"closed">>) -> buys_nothing.

battle_season(true) -> battles_being_created;
battle_season(false) -> battles_over.

only_the_figures_the_php_prints(
  {refused, {would_spend_into_the_reserve, #{reserve_units := Reserve,
                                             teams_after := TeamsAfter}}}) ->
    {refused, {would_spend_into_the_reserve, #{reserve_units => Reserve,
                                               teams_after => TeamsAfter}}};
only_the_figures_the_php_prints(Decision) ->
    Decision.

php(_In, #{<<"ok">> := true, <<"mode">> := <<"execute">>}) ->
    execute;
php(_In, #{<<"ok">> := true, <<"mode">> := <<"queue">>, <<"why">> := Why}) ->
    {queue, reason(Why)};
php(#{<<"snapshot">> := #{<<"mv">> := MarketValue}},
    #{<<"ok">> := false, <<"error">> := <<"A bid must be more than $0.">>}) ->
    {refused, {below_market_value, MarketValue}};
php(#{<<"snapshot">> := #{<<"rank_pos">> := Position}},
    #{<<"ok">> := false, <<"error">> := Error}) ->
    {refused, refusal(Error, Position)}.

reason(<<"it is carrying a live Battle">>) -> live_battle;
reason(<<"its game is in progress">>) -> in_game;
reason(<<"it plays within the next 30 minutes">>) -> kickoff_imminent;
reason(<<"this week's results have not been priced yet">>) -> unpriced;
reason(<<"no poll has priced this week's results yet">>) -> no_opening_yet;
reason(<<"it is held against the order you filed it with", _/binary>>) ->
    held_against_its_acquisition.

refusal(Error, Position) ->
    case [Refusal || {Phrase, Refusal} <- refusals(), mentions(Error, Phrase)] of
        [{below_market_value, value}] ->
            {below_market_value, units(<<"Market Value \\(\\$([\\d,.]+)\\)">>, Error)};
        [{ranked_outside_the_top_12, position}] ->
            {ranked_outside_the_top_12, Position};
        [{would_spend_into_the_reserve, figures}] ->
            Reserve = units(<<"and \\$([\\d,.]+) (has|would have) to stay back">>, Error),
            TeamsAfter = units(<<" for (\\d+) teams?">>, Error),
            {would_spend_into_the_reserve, #{reserve_units => Reserve,
                                             teams_after => TeamsAfter}};
        [Refusal] ->
            Refusal
    end.

refusals() ->
    [{<<"The season is over">>, season_over},
     {<<"once the draft is complete">>, {market_opens_after_the_draft, drafting}},
     {<<"once the preseason draft">>, {market_opens_after_the_draft, before_the_draft}},
     {<<"You already have an order for">>, already_ordered_this_window},
     {<<"You are under Margin Call">>, in_margin_call},
     {<<"is part of a trade you have not settled">>, in_pending_trade},
     {<<"so this order queues to the next opening">>, queued_so_file_a_conditional_drop},
     {<<"Only an acquisition can make room">>, only_an_acquisition_makes_room},
     {<<"You do not hold the team you offered">>, you_do_not_hold_the_team_to_drop},
     {<<"You cannot give up">>, cannot_drop_the_team_being_acquired},
     {<<"is committed to a pending trade">>, team_to_drop_is_in_pending_trade},
     {<<"already has an order this window">>, team_to_drop_already_has_an_order},
     {<<"so it cannot be released now">>, team_to_drop_is_off_the_board},
     {<<"so add it free instead of bidding">>, unranked_so_add_it_free},
     {<<"ranked teams are acquired by bidding">>, ranked_so_bid_for_it},
     {<<"You already own">>, you_already_own_it},
     {<<"is owned by another owner">>, owned_by_another_owner},
     {<<"is already owned.">>, owned_by_another_owner},
     {<<"Drop or sell one first">>, at_the_maximum_with_nothing_queued_to_make_room},
     {<<"at least the Market Value">>, {below_market_value, value}},
     {<<"would leave you short">>, {would_spend_into_the_reserve, figures}},
     {<<"needs a Battle stake behind it">>, {would_spend_into_the_reserve, figures}},
     {<<"You do not own that team.">>, not_your_team},
     {<<"The House stopped buying">>, house_stopped_buying},
     {<<"the House only buys teams in the AP or CFP Top 25">>, unranked},
     {<<"the House now only buys teams in the top">>,
      {ranked_outside_the_top_12, position}}].

mentions(Error, Phrase) ->
    string:find(Error, Phrase) =/= nomatch.

units(Pattern, Error) ->
    {match, [Number | _]} =
        re:run(Error, Pattern, [unicode, {capture, all_but_first, binary}]),
    binary_to_integer(binary:replace(binary:replace(Number, <<",">>, <<>>, [global]),
                                     <<".">>, <<>>)).
