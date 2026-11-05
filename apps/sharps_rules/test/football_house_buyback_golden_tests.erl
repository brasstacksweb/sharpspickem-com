-module(football_house_buyback_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_stage_and_rank_buys_as_the_php_did_test() ->
    ?assertEqual([], golden:disagreements("house_will_buy", fun will_buy/1,
                                          fun php_will_buy/2)).

every_recorded_sale_settles_as_the_php_settled_it_test() ->
    ?assertEqual([], golden:disagreements("decide_sale", fun sale/1, fun php_sale/2)).

every_recorded_forecast_warns_as_the_php_did_test() ->
    ?assertEqual([], golden:disagreements("decide_buyback_forecast", fun forecast/1,
                                          fun php_forecast/2)).

will_buy(#{<<"stage">> := Stage, <<"rankPos">> := Position}) ->
    football_house_buyback:will_buy(stage(Stage), rank(Position)).

php_will_buy(#{<<"stage">> := Stage, <<"rankPos">> := Position}, true) ->
    football_house_buyback:will_buy(stage(Stage), rank(Position)) =:= yes andalso yes;
php_will_buy(#{<<"stage">> := <<"closed">>}, false) ->
    {no, house_stopped_buying};
php_will_buy(#{<<"rankPos">> := null}, false) ->
    {no, unranked};
php_will_buy(#{<<"rankPos">> := Position}, false) ->
    {no, {ranked_outside_the_top_12, Position}}.

sale(#{<<"team">> := Team, <<"stage">> := Stage, <<"marketValue">> := MarketValue,
       <<"houseBalance">> := HouseBalance, <<"rankPos">> := Position}) ->
    football_house_buyback:decide(#{team => team(Team), stage => stage(Stage),
                                    rank => rank(Position),
                                    market_value_units => MarketValue,
                                    house_balance_units => HouseBalance}).

team(null) ->
    not_owned_by_seller;
team(#{<<"acquired_price_cents">> := Basis}) ->
    {owned_by_seller, #{basis_units => Basis}}.

php_sale(#{<<"team">> := null}, #{<<"ok">> := false}) ->
    {refused, not_your_team};
php_sale(_In, #{<<"ok">> := true, <<"mv">> := Price, <<"basis">> := Basis}) ->
    {sell, #{price_units => Price, basis_units => Basis}};
php_sale(#{<<"rankPos">> := Position}, #{<<"ok">> := false, <<"error">> := Error}) ->
    {refused, sale_refusal(Error, Position)}.

sale_refusal(<<"The House stopped buying", _/binary>>, _Position) -> house_stopped_buying;
sale_refusal(<<"You do not own that team">>, _Position) -> not_your_team;
sale_refusal(<<"The House Account cannot cover", _/binary>>, _Position) ->
    house_cannot_cover;
sale_refusal(Error, null) -> mentions(Error, <<"is unranked">>) andalso unranked;
sale_refusal(Error, Position) ->
    mentions(Error, <<"is ranked #">>) andalso {ranked_outside_the_top_12, Position}.

mentions(Error, Phrase) ->
    string:find(Error, Phrase) =/= nomatch.

forecast(#{<<"stage">> := Stage, <<"expectedOn">> := ExpectedOn, <<"nowTs">> := Now,
           <<"tz">> := <<"UTC">>}) ->
    {Today, _Time} = calendar:system_time_to_universal_time(Now, second),
    football_house_buyback:forecast(#{stage => stage(Stage),
                                      next_boundary => boundary(ExpectedOn),
                                      today => {league_local, Today}}).

boundary(null) -> not_set;
boundary(<<>>) -> not_set;
boundary(Date) -> league_date(Date).

php_forecast(_In, null) ->
    nothing_to_warn;
php_forecast(_In, #{<<"next_stage">> := NextStage, <<"expected_on">> := On,
                    <<"days">> := Days}) ->
    {narrows, #{to => stage(NextStage), on => league_date(On), in_days => Days}}.

stage(<<"open">>) -> buys_the_top_25;
stage(<<"top12">>) -> buys_the_top_12;
stage(<<"closed">>) -> buys_nothing.

rank(null) -> unranked;
rank(Position) -> {ranked, Position}.

league_date(<<Year:4/binary, "-", Month:2/binary, "-", Day:2/binary>>) ->
    {league_local, {binary_to_integer(Year), binary_to_integer(Month),
                    binary_to_integer(Day)}}.
