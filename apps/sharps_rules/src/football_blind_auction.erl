-module(football_blind_auction).

-rule("§7").

-export([resolve/1]).

-export_type([auction/0, lot/0, bid/0, drop/0, decision/0]).

-type units() :: non_neg_integer().

-type owner() :: term().

-type team() :: term().

-type bid() :: #{
    bid := term(),
    owner := owner(),
    amount_units := units(),
    queued_at := term(),
    priority := integer()
}.

-type lot() :: #{
    team := team(),
    house_owned := boolean(),
    extra_games_this_week := non_neg_integer(),
    bids := [bid()]
}.

-type drop() :: #{extra_games_this_week := non_neg_integer(), term() => term()}.

-type owner_state() :: #{
    funds_units := units(),
    escrow_units := units(),
    teams_held := non_neg_integer(),
    extra_games_this_week := non_neg_integer()
}.

-type auction() :: #{
    lots := [lot()],
    owners := #{owner() => owner_state()},
    drops := #{owner() => [drop()]},
    max_teams := non_neg_integer(),
    stake_units := units(),
    battle_season := football_battle_reserve:battle_season()
}.

-type rejection() ::
    insufficient_funds
  | over_the_maximum_with_no_drop
  | {would_spend_into_the_reserve, map()}.

-type decision() ::
    {skipped, team(), no_longer_a_house_team}
  | {void, team(), bid(), rejection()}
  | {won, team(), bid(), {dropping, drop()} | no_drop}.

-spec resolve(auction()) -> [decision()].
resolve(#{lots := Lots} = Auction) ->
    HouseLots = [Lot || #{house_owned := true} = Lot <- Lots],
    {Accepted, Rejected} = until_no_one_is_rejected(HouseLots, Auction, #{}),
    lists:append([report(Lot, Accepted, Rejected) || Lot <- Lots]).

until_no_one_is_rejected(Lots, Auction, Rejected) ->
    {Accepted, NewlyRejected} = one_round(Lots, Auction, Rejected),
    case map_size(NewlyRejected) of
        0 -> {Accepted, Rejected};
        _ -> until_no_one_is_rejected(Lots, Auction, maps:merge(Rejected, NewlyRejected))
    end.

one_round(Lots, Auction, Rejected) ->
    Nominations = [{Owner, {Lot, Bid}}
                   || Lot <- Lots,
                      #{owner := Owner} = Bid <- best_surviving(Lot, Rejected)],
    ByOwner = maps:groups_from_list(fun({Owner, _Nomination}) -> Owner end,
                                    fun({_Owner, Nomination}) -> Nomination end,
                                    Nominations),
    Rounds = [owner_round(Owner, in_their_priority_order(OwnersNominations), Auction)
              || Owner := OwnersNominations <- ByOwner],
    {merged(accepted, Rounds), merged(rejected, Rounds)}.

best_surviving(#{team := Team, bids := Bids}, Rejected) ->
    lists:sublist([Bid || #{bid := BidId} = Bid <- highest_first(Bids),
                          not is_map_key({Team, BidId}, Rejected)], 1).

highest_first(Bids) ->
    lists:sort(fun(Bid, Other) -> bid_order(Bid) =< bid_order(Other) end, Bids).

bid_order(#{amount_units := Amount, queued_at := QueuedAt}) ->
    {-Amount, QueuedAt}.

in_their_priority_order(Nominations) ->
    lists:sort(fun({_Lot, Bid}, {_OtherLot, Other}) -> ranking(Bid) =< ranking(Other) end,
               Nominations).

ranking(#{priority := Priority, bid := BidId}) ->
    {Priority, BidId}.

owner_round(Owner, Nominations, #{owners := Owners, drops := Drops} = Auction) ->
    #{Owner := Before} = Owners,
    Start = Before#{drops_left => maps:get(Owner, Drops, []),
                    accepted => #{},
                    rejected => #{}},
    lists:foldl(fun({Lot, Bid}, Position) -> consider(Lot, Bid, Position, Auction) end,
                Start, Nominations).

consider(#{team := Team} = Lot, #{bid := BidId} = Bid, Position, Auction) ->
    case verdict(Lot, Bid, Position, Auction) of
        accept ->
            win(Lot, Bid, Position, Auction);
        {reject, Rejection} ->
            #{rejected := Rejected} = Position,
            Position#{rejected := Rejected#{{Team, BidId} => Rejection}}
    end.

verdict(_Lot, #{amount_units := Amount}, #{funds_units := Funds}, _Auction)
  when Funds < Amount ->
    {reject, insufficient_funds};
verdict(_Lot, _Bid, #{teams_held := TeamsHeld, drops_left := []},
        #{max_teams := MaxTeams})
  when TeamsHeld >= MaxTeams ->
    {reject, over_the_maximum_with_no_drop};
verdict(Lot, Bid, Position, Auction) ->
    After = after_winning(Lot, Bid, Position, Auction),
    within_the_reserve(football_battle_reserve:headroom(After)).

within_the_reserve({fits, _Figures}) -> accept;
within_the_reserve({spends_into_the_reserve, Figures}) ->
    {reject, {would_spend_into_the_reserve, Figures}}.

after_winning(#{extra_games_this_week := LotExtraGames}, #{amount_units := Amount},
              #{funds_units := Funds, escrow_units := Escrow, teams_held := TeamsHeld,
                extra_games_this_week := ExtraGames, drops_left := DropsLeft},
              #{max_teams := MaxTeams, stake_units := Stake, battle_season := Season}) ->
    {Drop, _DropsAfter, TeamsAfter} = make_room(TeamsHeld, MaxTeams, DropsLeft),
    #{funds_units => Funds, cash_out_units => Amount, escrow_units => Escrow,
      teams_held => TeamsAfter, teams_gained => 0, max_teams => MaxTeams,
      extra_games_this_week => extra_games_after(ExtraGames, Drop) + LotExtraGames,
      stake_units => Stake,
      battle_season => Season}.

win(#{team := Team, extra_games_this_week := LotExtraGames},
    #{amount_units := Amount} = Bid,
    #{funds_units := Funds, teams_held := TeamsHeld, extra_games_this_week := ExtraGames,
      drops_left := DropsLeft, accepted := Accepted} = Position,
    #{max_teams := MaxTeams}) ->
    {Drop, DropsAfter, TeamsAfter} = make_room(TeamsHeld, MaxTeams, DropsLeft),
    Position#{funds_units := Funds - Amount,
              teams_held := TeamsAfter,
              extra_games_this_week := extra_games_after(ExtraGames, Drop) + LotExtraGames,
              drops_left := DropsAfter,
              accepted := Accepted#{Team => {Bid, Drop}}}.

extra_games_after(ExtraGames, no_drop) ->
    ExtraGames;
extra_games_after(ExtraGames, {dropping, #{extra_games_this_week := Released}}) ->
    max(0, ExtraGames - Released).

make_room(TeamsHeld, MaxTeams, [Drop | LaterDrops]) when TeamsHeld >= MaxTeams ->
    {{dropping, Drop}, LaterDrops, TeamsHeld};
make_room(TeamsHeld, _MaxTeams, DropsLeft) ->
    {no_drop, DropsLeft, TeamsHeld + 1}.

merged(Key, Rounds) ->
    lists:foldl(fun(Round, Merged) -> maps:merge(Merged, maps:get(Key, Round)) end,
                #{}, Rounds).

report(#{house_owned := false, team := Team}, _Accepted, _Rejected) ->
    [{skipped, Team, no_longer_a_house_team}];
report(#{team := Team, bids := Bids}, Accepted, Rejected) ->
    down_the_bids(Team, highest_first(Bids), maps:get(Team, Accepted, none), Rejected).

down_the_bids(Team, [Bid | _Lower], {Bid, Drop}, _Rejected) ->
    [{won, Team, Bid, Drop}];
down_the_bids(Team, [#{bid := BidId} = Bid | Lower], Winner, Rejected) ->
    case Rejected of
        #{{Team, BidId} := Rejection} ->
            [{void, Team, Bid, Rejection} | down_the_bids(Team, Lower, Winner, Rejected)];
        #{} ->
            []
    end;
down_the_bids(_Team, [], _Winner, _Rejected) ->
    [].
