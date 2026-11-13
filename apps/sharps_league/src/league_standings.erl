-module(league_standings).

-export([portfolio/3, standings/2]).

-define(PUT_IN_BY_HAND, [commissioner_adjustment, season_settlement]).

-type utc() :: {utc, integer()}.

-spec portfolio(binary(), utc(), league_state:state()) -> football_portfolio:portfolio().
portfolio(Owner, Now, State) ->
    football_portfolio:value(
      #{stage => league_state:buyback_stage(Now, State),
        holdings => [#{rank => league_state:rank(Team, State),
                       market_value_units => league_state:market_value(Team, State)}
                     || Team <- league_state:held_by(Owner, State)],
        cash_units => league_state:funds(Owner, State),
        contributed_units => proplists:get_value(Owner, league_state:contributions(State)),
        adjustments_units => lists:sum([Amount
                                        || #{owner := Holder, type := Type,
                                             amount_units := Amount}
                                               <- league_state:owner_ledger(State),
                                           Holder =:= Owner,
                                           lists:member(Type, ?PUT_IN_BY_HAND)])}).

-spec standings(utc(), league_state:state()) -> [football_portfolio:standing()].
standings(Now, #{owner_order := Owners} = State) ->
    football_portfolio:standings(
      [maps:merge(#{owner => Owner},
                  maps:with([alpha_units, portfolio_value_units],
                            portfolio(Owner, Now, State)))
       || Owner <- Owners]).
