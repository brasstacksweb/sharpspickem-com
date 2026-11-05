-module(football_house_buyback).

-rule("§8").

-export([will_buy/2, decide/1, forecast/1]).

-export_type([stage/0, rank/0, refusal/0, sale/0, forecast/0]).

-type units() :: non_neg_integer().

-type stage() :: buys_the_top_25 | buys_the_top_12 | buys_nothing.

-type rank() :: {ranked, 1..25} | unranked.

-type league_date() :: {league_local, calendar:date()}.

-type refusal() ::
    house_stopped_buying
  | unranked
  | {ranked_outside_the_top_12, 13..25}
  | not_your_team
  | house_cannot_cover.

-type sale() :: #{
    team := {owned_by_seller, #{basis_units := units()}} | not_owned_by_seller,
    stage := stage(),
    rank := rank(),
    market_value_units := units(),
    house_balance_units := units()
}.

-type forecast() ::
    nothing_to_warn
  | {narrows, #{to := buys_the_top_12 | buys_nothing,
                on := league_date(),
                in_days := non_neg_integer()}}.

-spec will_buy(stage(), rank()) -> yes | {no, refusal()}.
will_buy(buys_nothing, _Rank) ->
    {no, house_stopped_buying};
will_buy(_Stage, unranked) ->
    {no, unranked};
will_buy(buys_the_top_12, {ranked, Position}) when Position > 12 ->
    {no, {ranked_outside_the_top_12, Position}};
will_buy(_Stage, {ranked, _Position}) ->
    yes.

-spec decide(sale()) -> {sell, #{price_units := units(), basis_units := units()}}
                      | {refused, refusal()}.
decide(#{team := not_owned_by_seller}) ->
    {refused, not_your_team};
decide(#{stage := Stage, rank := Rank} = Sale) ->
    once_the_house_will_buy(will_buy(Stage, Rank), Sale).

once_the_house_will_buy({no, Refusal}, _Sale) ->
    {refused, Refusal};
once_the_house_will_buy(yes, #{market_value_units := MarketValue,
                               house_balance_units := HouseBalance})
  when HouseBalance < MarketValue ->
    {refused, house_cannot_cover};
once_the_house_will_buy(yes, #{market_value_units := MarketValue,
                               team := {owned_by_seller, #{basis_units := Basis}}}) ->
    {sell, #{price_units => MarketValue, basis_units => Basis}}.

-spec forecast(#{stage := stage(),
                 next_boundary := league_date() | not_set,
                 today := league_date()}) -> forecast().
forecast(#{stage := buys_nothing}) ->
    nothing_to_warn;
forecast(#{next_boundary := not_set}) ->
    nothing_to_warn;
forecast(#{stage := Stage, next_boundary := {league_local, Boundary},
           today := {league_local, Today}}) ->
    days_until(next_stage(Stage), Boundary,
               calendar:date_to_gregorian_days(Boundary)
                   - calendar:date_to_gregorian_days(Today)).

days_until(_NextStage, _Boundary, DaysAway) when DaysAway < 0 ->
    nothing_to_warn;
days_until(NextStage, Boundary, DaysAway) ->
    {narrows, #{to => NextStage, on => {league_local, Boundary}, in_days => DaysAway}}.

next_stage(buys_the_top_25) -> buys_the_top_12;
next_stage(buys_the_top_12) -> buys_nothing.
