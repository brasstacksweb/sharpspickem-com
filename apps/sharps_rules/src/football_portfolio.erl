-module(football_portfolio).

-rule("§4").
-ruled_by(spencer).

-export([value/1, standings/1]).

-export_type([portfolio/0, standing/0]).

-type units() :: integer().

-type holding() :: #{rank := football_house_buyback:rank(), market_value_units := units()}.

-type position() :: #{
    stage := football_house_buyback:stage(),
    holdings := [holding()],
    cash_units := units(),
    contributed_units := units(),
    adjustments_units := units()
}.

-type portfolio() :: #{team_value_units := units(), portfolio_value_units := units(),
                       alpha_units := units()}.

-type standing() :: #{owner := term(), rank := pos_integer(), alpha_units := units(),
                      portfolio_value_units := units()}.

-spec value(position()) -> portfolio().
value(#{stage := Stage, holdings := Holdings, cash_units := Cash,
        contributed_units := Contributed, adjustments_units := Adjustments}) ->
    TeamValue = lists:sum([worth(Stage, Holding) || Holding <- Holdings]),
    #{team_value_units => TeamValue, portfolio_value_units => TeamValue + Cash,
      alpha_units => TeamValue + Cash - Contributed - Adjustments}.

worth(Stage, #{rank := Rank, market_value_units := MarketValue}) ->
    case football_house_buyback:will_buy(Stage, Rank) of
        yes -> MarketValue;
        {no, _Why} -> 0
    end.

-spec standings([#{owner := term(), alpha_units := units(),
                   portfolio_value_units := units()}]) -> [standing()].
standings(Owners) ->
    Alphas = [Alpha || #{alpha_units := Alpha} <- Owners],
    Ranked = [Owner#{rank => 1 + length([Higher || Higher <- Alphas, Higher > Alpha])}
              || #{alpha_units := Alpha} = Owner <- Owners],
    lists:sort(fun ranked_before/2, Ranked).

ranked_before(#{rank := Rank, portfolio_value_units := Value},
              #{rank := OtherRank, portfolio_value_units := OtherValue}) ->
    {Rank, -Value} =< {OtherRank, -OtherValue}.
