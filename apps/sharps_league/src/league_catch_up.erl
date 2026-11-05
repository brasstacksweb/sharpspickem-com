-module(league_catch_up).

-export([catch_up/2]).

-type utc() :: {utc, integer()}.

-spec catch_up(utc(), league_state:state()) -> [league_state:event()].
catch_up(Now, State) ->
    {Events, _CaughtUp} =
        lists:foldl(fun(Step, {SoFar, Before}) ->
                            New = step(Step, Now, Before),
                            {SoFar ++ New, fold(New, Before)}
                    end, {[], State}, [openings, bind, settle, create]),
    Events.

step(openings, Now, State) -> openings(Now, State);
step(bind, Now, State) -> league_battles:bound(Now, State);
step(settle, Now, State) -> league_battles:settled(Now, State);
step(create, Now, State) -> battles_created(Now, State).

openings(Now, State) ->
    Due = [Opening || #{at := At} = Opening <- lists:sort(league_state:openings(State)),
                      At =< Now],
    lists:foldl(fun(Opening, Events) ->
                        Events ++ settled(Opening, Now, fold(Events, State))
                end, [], Due).

settled(#{priced := true} = Opening, Now, State) ->
    league_opening:settle(Opening, Now, State#{last_priced_opening := Now});
settled(Opening, Now, State) ->
    league_opening:settle(Opening, Now, State).

battles_created(Now, #{draft := #{stage := complete}} = State) ->
    league_battles:created(Now, State);
battles_created(_Now, _BeforeTheSeason) ->
    [].

fold(Events, State) ->
    lists:foldl(fun league_state:apply_event/2, State, Events).
