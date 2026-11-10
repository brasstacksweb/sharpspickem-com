-module(league_playoff).

-export([frozen/2, paid/2]).

-type utc() :: {utc, integer()}.

-spec frozen(utc(), league_state:state()) -> [league_state:event()].
frozen(Now, State) ->
    case {league_state:battle_season(Now, State), league_state:prize_pool(State)} of
        {battles_over, not_frozen} ->
            [{prize_pool_frozen, league_state:house_balance(State)}];
        {_Season, _PoolOrNot} ->
            []
    end.

-spec paid(utc(), league_state:state()) -> [league_state:event()].
paid(Now, State) ->
    case league_state:prize_pool(State) of
        not_frozen -> [];
        Pool -> slots_paid(Pool, Now, State)
    end.

slots_paid(Pool, Now, State) ->
    #{slots := Won} = football_playoff:slots(bracket(Now, State)),
    {Events, _AfterThem} =
        lists:foldl(fun(Slot, {SoFar, Before}) ->
                            New = slot_paid(Slot, Pool, Before),
                            {SoFar ++ New,
                             lists:foldl(fun league_state:apply_event/2, Before, New)}
                    end, {[], State}, Won),
    Events.

bracket(Now, State) ->
    [playoff_game(Game, Now) || #{season_type := postseason, notes := _Notes} = Game
                                    <- league_state:games(State)].

playoff_game(#{final_at := FinalAt} = Game, Now) when FinalAt =< Now ->
    (maps:with([home_team, away_team, notes, home_points, away_points], Game))#{
        completed => true};
playoff_game(Game, _Now) ->
    (maps:with([home_team, away_team, notes], Game))#{completed => false}.

slot_paid(#{round := Round, team := Team}, Pool, State) ->
    case {already_recorded(Round, Team, State), league_state:team(Team, State)} of
        {true, _Held} -> [];
        {false, not_in_the_league} -> [];
        {false, #{owner := Holder}} -> decided(Round, Team, Holder, Pool, State)
    end.

already_recorded(Round, Team, State) ->
    lists:any(fun(#{round := SlotRound, team := SlotTeam}) ->
                      {SlotRound, SlotTeam} =:= {Round, Team}
              end, league_state:playoff_slots(State)).

decided(Round, Team, Holder, Pool, State) ->
    Share = football_playoff_payout:share(#{pool_units => Pool,
                                            recorded => league_state:playoff_slots(State),
                                            round => Round, winner => winner(Holder)}),
    as_events(Share, #{round => Round, team => Team}, Holder, State).

winner(house) -> house_owned;
winner(_Owner) -> owned.

as_events({pay_units, Units}, Slot, Owner, _State) ->
    [{playoff_share_paid, Slot#{owner => Owner, amount_units => Units}}];
as_events({forfeited, rolls_into_later_rounds}, Slot, house, _State) ->
    [{playoff_share_forfeited, Slot}];
as_events({forfeited, {refund_to_owners_units, Remainder}}, Slot, house, State) ->
    [{playoff_share_forfeited, Slot}
     | refunded(football_playoff_payout:refund(Remainder,
                                               league_state:contributions(State)))].

refunded([]) -> [];
refunded(Shares) -> [{prize_pool_refunded, Shares}].
