-module(football_market_order).

-rule("§6").

-export([decide/2]).

-export_type([order/0, snapshot/0, decision/0, refusal/0]).

-type units() :: integer().

-type owner() :: term().

-type team() :: term().

-type kind() :: {bid, units()} | add | drop | conditional_drop | sale.

-type team_to_drop() :: #{
    team := team(),
    owner := owner() | house,
    available := football_availability:answer(),
    in_pending_trade := boolean(),
    has_your_order := boolean(),
    proceeds_units := units(),
    extra_games_this_week := non_neg_integer()
}.

-type order() :: #{
    kind := kind(),
    making_room := no | {by_dropping, team_to_drop()}
}.

-type snapshot() :: #{
    season := before_the_draft | drafting | running | over,
    you := #{
        owner := owner(),
        funds_units := units(),
        escrow_units := units(),
        teams_held := non_neg_integer(),
        extra_games_this_week := non_neg_integer(),
        committed_to_bids_units := units(),
        teams_pending := non_neg_integer()
    },
    team := #{
        team := team(),
        owner := owner() | house,
        rank := football_house_buyback:rank(),
        market_value_units := units(),
        extra_games_this_week := non_neg_integer(),
        available := football_availability:answer(),
        in_pending_trade := boolean(),
        has_your_order := boolean()
    },
    buyback_stage := football_house_buyback:stage(),
    max_teams := non_neg_integer(),
    stake_units := units(),
    battle_season := football_battle_reserve:battle_season()
}.

-type refusal() ::
    season_over
  | {market_opens_after_the_draft, before_the_draft | drafting}
  | already_ordered_this_window
  | in_margin_call
  | in_pending_trade
  | queued_so_file_a_conditional_drop
  | only_an_acquisition_makes_room
  | you_do_not_hold_the_team_to_drop
  | cannot_drop_the_team_being_acquired
  | team_to_drop_is_in_pending_trade
  | team_to_drop_already_has_an_order
  | team_to_drop_is_off_the_board
  | unranked_so_add_it_free
  | ranked_so_bid_for_it
  | you_already_own_it
  | owned_by_another_owner
  | not_your_team
  | at_the_maximum_with_nothing_queued_to_make_room
  | {below_market_value, units()}
  | {would_spend_into_the_reserve, map()}
  | football_house_buyback:refusal().

-type decision() ::
    execute
  | {queue, football_availability:reason() | held_against_its_acquisition}
  | {refused, refusal()}.

-spec decide(order(), snapshot()) -> decision().
decide(#{kind := Kind} = Order, Snapshot) ->
    maybe
        ok ?= market_open(Snapshot),
        ok ?= one_order_per_team(Snapshot),
        ok ?= margin_call_allows(Kind, Snapshot),
        ok ?= not_promised_in_a_trade(Snapshot),
        Mode = mode(Kind, Snapshot),
        {ok, YouAfterTheDrop} ?= making_room(Order, Mode, Snapshot),
        ok ?= the_kind_allows(Kind, Mode, Snapshot#{you := YouAfterTheDrop}),
        Mode
    else
        {refused, _Why} = Refused -> Refused
    end.

market_open(#{season := running}) -> ok;
market_open(#{season := over}) -> {refused, season_over};
market_open(#{season := Before}) -> {refused, {market_opens_after_the_draft, Before}}.

one_order_per_team(#{team := #{has_your_order := true}}) ->
    {refused, already_ordered_this_window};
one_order_per_team(_Snapshot) ->
    ok.

margin_call_allows({bid, _Amount}, Snapshot) -> in_good_standing(Snapshot);
margin_call_allows(add, Snapshot) -> in_good_standing(Snapshot);
margin_call_allows(_ReducesExposure, _Snapshot) -> ok.

in_good_standing(Snapshot) ->
    case standing(Snapshot) of
        in_good_standing -> ok;
        in_margin_call -> {refused, in_margin_call}
    end.

not_promised_in_a_trade(#{team := #{in_pending_trade := true}}) ->
    {refused, in_pending_trade};
not_promised_in_a_trade(_Snapshot) ->
    ok.

mode(conditional_drop, _Snapshot) -> {queue, held_against_its_acquisition};
mode(_Kind, #{team := #{available := yes}}) -> execute;
mode(_Kind, #{team := #{available := {no, Why}}}) -> {queue, Why}.

making_room(#{making_room := no}, _Mode, #{you := You}) ->
    {ok, You};
making_room(_Order, {queue, _Why}, _Snapshot) ->
    {refused, queued_so_file_a_conditional_drop};
making_room(#{kind := {bid, _Amount}} = Order, execute, Snapshot) ->
    drop_to_make_room(Order, Snapshot);
making_room(#{kind := add} = Order, execute, Snapshot) ->
    drop_to_make_room(Order, Snapshot);
making_room(_DropOrSale, execute, _Snapshot) ->
    {refused, only_an_acquisition_makes_room}.

drop_to_make_room(#{making_room := {by_dropping, Drop}}, #{you := You, team := Team}) ->
    maybe
        ok ?= droppable(Drop, You, Team),
        {ok, after_dropping(Drop, You)}
    end.

droppable(#{owner := Owner}, #{owner := You}, _Team) when Owner =/= You ->
    {refused, you_do_not_hold_the_team_to_drop};
droppable(#{team := Same}, _You, #{team := Same}) ->
    {refused, cannot_drop_the_team_being_acquired};
droppable(#{in_pending_trade := true}, _You, _Team) ->
    {refused, team_to_drop_is_in_pending_trade};
droppable(#{has_your_order := true}, _You, _Team) ->
    {refused, team_to_drop_already_has_an_order};
droppable(#{available := {no, _Why}}, _You, _Team) ->
    {refused, team_to_drop_is_off_the_board};
droppable(#{available := yes}, _You, _Team) ->
    ok.

after_dropping(#{proceeds_units := Proceeds, extra_games_this_week := DroppedGames},
               #{funds_units := Funds, teams_held := TeamsHeld,
                 extra_games_this_week := ExtraGames} = You) ->
    You#{funds_units := Funds + Proceeds,
         teams_held := max(0, TeamsHeld - 1),
         extra_games_this_week := max(0, ExtraGames - DroppedGames)}.

the_kind_allows({bid, Amount}, Mode,
                #{team := #{owner := house, rank := {ranked, _},
                            market_value_units := MarketValue}} = Snapshot) ->
    maybe
        ok ?= room_now(Mode, Snapshot),
        ok ?= at_least_market_value(Amount, MarketValue),
        within_the_reserve(Amount, Snapshot)
    end;
the_kind_allows({bid, _Amount}, _Mode, #{team := #{owner := house, rank := unranked}}) ->
    {refused, unranked_so_add_it_free};
the_kind_allows(add, Mode, #{team := #{owner := house, rank := unranked}} = Snapshot) ->
    maybe
        ok ?= room_now(Mode, Snapshot),
        within_the_reserve(0, Snapshot)
    end;
the_kind_allows(add, _Mode, #{team := #{owner := house, rank := {ranked, _}}}) ->
    {refused, ranked_so_bid_for_it};
the_kind_allows({bid, _Amount}, _Mode,
                #{you := #{owner := You}, team := #{owner := You}}) ->
    {refused, you_already_own_it};
the_kind_allows(add, _Mode, #{you := #{owner := You}, team := #{owner := You}}) ->
    {refused, you_already_own_it};
the_kind_allows({bid, _Amount}, _Mode, _OwnedByAnotherOwner) ->
    {refused, owned_by_another_owner};
the_kind_allows(add, _Mode, _OwnedByAnotherOwner) ->
    {refused, owned_by_another_owner};
the_kind_allows(sale, _Mode, #{you := #{owner := You},
                               team := #{owner := You, rank := Rank},
                               buyback_stage := Stage}) ->
    case football_house_buyback:will_buy(Stage, Rank) of
        yes -> ok;
        {no, Why} -> {refused, Why}
    end;
the_kind_allows(_DropOrConditionalDrop, _Mode, #{you := #{owner := You},
                                                 team := #{owner := You}}) ->
    ok;
the_kind_allows(_DropOrSale, _Mode, _NotYourTeam) ->
    {refused, not_your_team}.

room_now(execute, #{you := #{teams_held := TeamsHeld}, max_teams := MaxTeams})
  when TeamsHeld >= MaxTeams ->
    {refused, at_the_maximum_with_nothing_queued_to_make_room};
room_now(_Mode, _Snapshot) ->
    ok.

at_least_market_value(Amount, MarketValue) when Amount < MarketValue ->
    {refused, {below_market_value, MarketValue}};
at_least_market_value(_Amount, _MarketValue) ->
    ok.

within_the_reserve(Amount, Snapshot) ->
    case football_battle_reserve:headroom(reserve_basis(Amount, Snapshot)) of
        {fits, _Figures} ->
            ok;
        {spends_into_the_reserve, Figures} ->
            {refused, {would_spend_into_the_reserve, Figures}}
    end.

reserve_basis(Amount,
              #{you := #{funds_units := Funds, escrow_units := Escrow,
                         teams_held := TeamsHeld, teams_pending := TeamsPending,
                         extra_games_this_week := ExtraGames,
                         committed_to_bids_units := Committed},
                team := #{extra_games_this_week := TeamExtraGames},
                max_teams := MaxTeams, stake_units := Stake, battle_season := Season}) ->
    #{funds_units => Funds, cash_out_units => Committed + Amount, escrow_units => Escrow,
      teams_held => TeamsHeld, teams_gained => TeamsPending + 1, max_teams => MaxTeams,
      extra_games_this_week => ExtraGames + TeamExtraGames, stake_units => Stake,
      battle_season => Season}.

standing(#{you := #{funds_units := Funds, escrow_units := Escrow, teams_held := TeamsHeld,
                    extra_games_this_week := ExtraGames},
           stake_units := Stake, battle_season := Season}) ->
    {Standing, _Figures} = football_battle_reserve:margin_call(
        #{funds_units => Funds, escrow_units => Escrow, teams_held => TeamsHeld,
          extra_games_this_week => ExtraGames, stake_units => Stake,
          battle_season => Season}),
    Standing.
