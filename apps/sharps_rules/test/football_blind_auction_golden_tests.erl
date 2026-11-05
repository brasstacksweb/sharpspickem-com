-module(football_blind_auction_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_auction_resolves_as_the_php_resolved_it_test() ->
    ?assertEqual([], golden:disagreements("resolve_bids", fun port/1, fun php/2)).

port(#{<<"teams">> := Lots, <<"owners">> := Owners, <<"maxTeams">> := MaxTeams,
       <<"drops">> := Drops, <<"stake">> := Stake, <<"battlesPossible">> := Possible}) ->
    Decisions = football_blind_auction:resolve(
        #{lots => [lot(Lot) || Lot <- Lots],
          owners => #{binary_to_integer(Id) => owner(Owner) || Id := Owner <- Owners},
          drops => #{binary_to_integer(Id) => OwnersDrops || Id := OwnersDrops <- Drops},
          max_teams => MaxTeams, stake_units => Stake,
          battle_season => battle_season(Possible)}),
    [as_the_php_reports_it(Decision) || Decision <- Decisions].

lot(#{<<"team_id">> := Team, <<"is_house">> := HouseOwned,
      <<"extra_games">> := ExtraGames, <<"bids">> := Bids}) ->
    #{team => Team, house_owned => HouseOwned, extra_games_this_week => ExtraGames,
      bids => [bid(Bid, QueuedAt) || {QueuedAt, Bid} <- lists:enumerate(Bids)]}.

bid(#{<<"bid_id">> := BidId, <<"owner_id">> := Owner, <<"amount">> := Amount,
      <<"priority">> := Priority}, QueuedAt) ->
    #{bid => BidId, owner => Owner, amount_units => Amount, queued_at => QueuedAt,
      priority => Priority}.

owner(#{<<"funds">> := Funds, <<"teams">> := TeamsHeld, <<"extra_games">> := ExtraGames,
        <<"escrow">> := Escrow}) ->
    #{funds_units => Funds, escrow_units => Escrow, teams_held => TeamsHeld,
      extra_games_this_week => ExtraGames}.

battle_season(true) -> battles_being_created;
battle_season(false) -> battles_over.

as_the_php_reports_it({skipped, Team, no_longer_a_house_team}) ->
    {skipped, Team};
as_the_php_reports_it({void, Team, #{bid := BidId}, Why}) ->
    {void, Team, BidId, rejection(Why)};
as_the_php_reports_it({won, Team, #{bid := BidId},
                       {dropping, #{<<"drop_id">> := Drop}}}) ->
    {won, Team, BidId, {dropping, Drop}};
as_the_php_reports_it({won, Team, #{bid := BidId}, no_drop}) ->
    {won, Team, BidId, no_drop}.

rejection({would_spend_into_the_reserve, #{teams_after := TeamsAfter}}) ->
    {would_spend_into_the_reserve, TeamsAfter};
rejection(Why) ->
    Why.

php(#{<<"teams">> := Lots}, Decisions) ->
    [decision(Decision) || #{<<"team_id">> := Team} <- Lots,
                           Decision <- Decisions,
                           map_get(<<"team_id">>, Decision) =:= Team].

decision(#{<<"type">> := <<"skipped">>, <<"team_id">> := Team}) ->
    {skipped, Team};
decision(#{<<"type">> := <<"void">>, <<"team_id">> := Team, <<"bid_id">> := BidId,
           <<"reason">> := Reason}) ->
    {void, Team, BidId, reason(Reason)};
decision(#{<<"type">> := <<"won">>, <<"team_id">> := Team, <<"bid_id">> := BidId,
           <<"drop">> := null}) ->
    {won, Team, BidId, no_drop};
decision(#{<<"type">> := <<"won">>, <<"team_id">> := Team, <<"bid_id">> := BidId,
           <<"drop">> := #{<<"drop_id">> := Drop}}) ->
    {won, Team, BidId, {dropping, Drop}}.

reason(<<"insufficient Available Funds">>) ->
    insufficient_funds;
reason(<<"over the ", _/binary>>) ->
    over_the_maximum_with_no_drop;
reason(<<"not enough left over to cover the Battle stakes for ", Teams/binary>>) ->
    [Count | _Teams] = string:split(Teams, <<" ">>),
    {would_spend_into_the_reserve, binary_to_integer(Count)}.
