-module(football_draft).

-rule("§5").

-export([owner_at/2, on_the_clock/1, next/3, create/2, set_order/3, start/2, select/2,
         pass/3, undo/2]).

-export_type([owner/0, team/0, actor/0, slot/0, draft/0, pick/0, stage/0]).

-type owner() :: binary().

-type team() :: binary().

-type actor() :: #{owner := owner(), commissioner := boolean()}.

-type slot() :: {Round :: pos_integer(), Position :: pos_integer()}.

-type stage() :: setup | {picking, slot()} | complete.

-type pick() :: #{owner := owner(), team := team(), price_units := non_neg_integer(),
                  round := pos_integer()}.

-type draft() :: #{
    order := [owner()],
    stage := stage(),
    passed := [owner()],
    picks := [pick()]
}.

-type rosters() :: #{teams_held := #{owner() => non_neg_integer()},
                     max_teams := pos_integer()}.

-type board_team() :: #{team := team(), owner := owner() | house,
                        price_units := non_neg_integer()}.

-type selection() :: #{
    draft := draft(),
    team := board_team() | not_in_the_league,
    rosters := rosters(),
    holding := football_battle_reserve:spending()
}.

-spec owner_at([owner()], slot()) -> owner().
owner_at(Order, {Round, Position}) when Round rem 2 =:= 1 ->
    lists:nth(Position, Order);
owner_at(Order, {_EvenRound, Position}) ->
    lists:nth(length(Order) - Position + 1, Order).

-spec on_the_clock(draft()) -> owner() | no_one.
on_the_clock(#{stage := {picking, Slot}, order := Order}) -> owner_at(Order, Slot);
on_the_clock(#{}) -> no_one.

-spec next(draft(), slot(), rosters()) -> {picking, slot()} | complete.
next(#{order := Order} = Draft, {Round, Position}, Rosters)
  when Position >= length(Order) ->
    first_with_room(Draft, {Round + 1, 1}, Rosters);
next(Draft, {Round, Position}, Rosters) ->
    first_with_room(Draft, {Round, Position + 1}, Rosters).

first_with_room(_Draft, {Round, _Position}, #{max_teams := MaxTeams})
  when Round > MaxTeams ->
    complete;
first_with_room(#{order := Order} = Draft, Slot, #{teams_held := TeamsHeld,
                                                   max_teams := MaxTeams} = Rosters) ->
    case maps:get(owner_at(Order, Slot), TeamsHeld, 0) < MaxTeams of
        true -> {picking, Slot};
        false -> next(Draft, Slot, Rosters)
    end.

-spec create(actor(), no_draft | draft()) ->
    {created, [owner()]} | {refused, not_the_commissioner | a_draft_already_exists}.
create(#{commissioner := false}, _Draft) ->
    {refused, not_the_commissioner};
create(_Commissioner, no_draft) ->
    {created, []};
create(_Commissioner, #{}) ->
    {refused, a_draft_already_exists}.

-spec set_order(actor(), no_draft | draft(), [owner()]) ->
    {order_set, [owner()]}
  | {refused, not_the_commissioner | not_before_the_draft_starts
            | every_owner_exactly_once}.
set_order(#{commissioner := false}, _Draft, _Order) ->
    {refused, not_the_commissioner};
set_order(_Commissioner, #{stage := setup, order := Owners}, Order) ->
    case lists:sort(Owners) =:= lists:usort(Order) of
        true -> {order_set, uniquely(Order)};
        false -> {refused, every_owner_exactly_once}
    end;
set_order(_Commissioner, _NotInSetup, _Order) ->
    {refused, not_before_the_draft_starts}.

uniquely(Order) ->
    lists:reverse(lists:foldl(fun keep_first/2, [], Order)).

keep_first(Owner, Kept) ->
    case lists:member(Owner, Kept) of
        true -> Kept;
        false -> [Owner | Kept]
    end.

-spec start(actor(), #{draft := no_draft | draft(), buyback_dates := set | not_set}) ->
    started
  | {refused, not_the_commissioner | no_draft_waiting | needs_two_owners
            | set_the_buyback_dates_first}.
start(#{commissioner := false}, _Setup) ->
    {refused, not_the_commissioner};
start(_Commissioner, #{draft := #{stage := setup, order := Order},
                       buyback_dates := Dates}) ->
    two_owners_and_the_dates(length(Order), Dates);
start(_Commissioner, _NoDraftWaiting) ->
    {refused, no_draft_waiting}.

two_owners_and_the_dates(Owners, _Dates) when Owners < 2 -> {refused, needs_two_owners};
two_owners_and_the_dates(_Owners, not_set) -> {refused, set_the_buyback_dates_first};
two_owners_and_the_dates(_Owners, set) -> started.

-spec select(actor(), selection()) ->
    {drafted, pick()}
  | {refused, no_draft_in_progress | not_your_turn | team_not_found | already_taken
            | at_the_maximum
            | {would_spend_into_the_reserve, football_battle_reserve:headroom()}}.
select(Actor, #{draft := Draft, team := Team, rosters := Rosters, holding := Holding}) ->
    maybe
        {ok, OnTheClock} ?= turn_of(Actor, Draft),
        {ok, #{team := Name, price_units := Price}} ?= on_the_board(Team),
        ok ?= room_on_the_roster(OnTheClock, Rosters),
        ok ?= within_the_reserve(Price, Holding),
        {picking, {Round, _Position}} = maps:get(stage, Draft),
        {drafted, #{owner => OnTheClock, team => Name, price_units => Price,
                    round => Round}}
    end.

turn_of(Actor, #{stage := {picking, _Slot}} = Draft) ->
    whose_turn(Actor, on_the_clock(Draft));
turn_of(_Actor, _NotPicking) ->
    {refused, no_draft_in_progress}.

whose_turn(#{commissioner := true}, OnTheClock) -> {ok, OnTheClock};
whose_turn(#{owner := OnTheClock}, OnTheClock) -> {ok, OnTheClock};
whose_turn(_SomeoneElse, _OnTheClock) -> {refused, not_your_turn}.

on_the_board(not_in_the_league) -> {refused, team_not_found};
on_the_board(#{owner := house} = Team) -> {ok, Team};
on_the_board(#{}) -> {refused, already_taken}.

room_on_the_roster(Owner, #{teams_held := TeamsHeld, max_teams := MaxTeams}) ->
    case maps:get(Owner, TeamsHeld, 0) < MaxTeams of
        true -> ok;
        false -> {refused, at_the_maximum}
    end.

within_the_reserve(Price, Holding) ->
    case football_battle_reserve:headroom(Holding#{cash_out_units := Price}) of
        {fits, _Figures} -> ok;
        Short -> {refused, {would_spend_into_the_reserve, Short}}
    end.

-spec pass(actor(), draft(), rosters()) ->
    {passed, owner(), stage()} | {refused, no_draft_in_progress | not_your_turn}.
pass(Actor, #{stage := {picking, Slot}, passed := Passed} = Draft,
     #{teams_held := TeamsHeld, max_teams := MaxTeams} = Rosters) ->
    maybe
        {ok, OnTheClock} ?= turn_of(Actor, Draft),
        StillDrafting = [Owner || Owner <- maps:get(order, Draft),
                                  maps:get(Owner, TeamsHeld, 0) < MaxTeams],
        PassedNow = lists:usort([OnTheClock | Passed]),
        YetToPass = StillDrafting -- PassedNow,
        {passed, OnTheClock, after_a_pass(YetToPass, Draft, Slot, Rosters)}
    end;
pass(_Actor, _NotPicking, _Rosters) ->
    {refused, no_draft_in_progress}.

after_a_pass([], _Draft, _Slot, _Rosters) -> complete;
after_a_pass(_YetToPass, Draft, Slot, Rosters) -> next(Draft, Slot, Rosters).

-spec undo(actor(), no_draft | draft()) ->
    {undone, pick(), slot()}
  | {refused, not_the_commissioner | no_draft_to_undo | no_picks_to_undo}.
undo(#{commissioner := false}, _Draft) ->
    {refused, not_the_commissioner};
undo(_Commissioner, #{stage := setup}) ->
    {refused, no_draft_to_undo};
undo(_Commissioner, #{picks := []}) ->
    {refused, no_picks_to_undo};
undo(_Commissioner, #{picks := [#{owner := Owner, round := Round} = Last | _Earlier],
                      order := Order}) ->
    {undone, Last, {Round, position_in_round(Order, Round, Owner)}};
undo(_Commissioner, no_draft) ->
    {refused, no_draft_to_undo}.

position_in_round(Order, Round, Owner) ->
    lists:min([Position || Position <- lists:seq(1, length(Order)),
                           owner_at(Order, {Round, Position}) =:= Owner]).
