-module(football_pricing_open_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_pricing_open_falls_where_the_php_put_it_test() ->
    ?assertEqual([], golden:disagreements("decide_next_pricing_open", fun port/1,
                                          fun php/2)).

port(#{<<"scheduled_at">> := Scheduled, <<"week">> := Week,
       <<"last_game_local">> := LastGame, <<"now_local">> := Now,
       <<"open_time">> := <<Hour:2/binary, ":", Minute:2/binary>>}) ->
    football_pricing_open:next(#{scheduled => scheduled(Scheduled), week => Week,
                                 last_game => last_game(LastGame),
                                 now => league_time(Now),
                                 open_time => {binary_to_integer(Hour),
                                               binary_to_integer(Minute)}}).

scheduled(null) -> not_scheduled;
scheduled(At) -> {utc, At}.

last_game(null) -> no_game;
last_game(Kickoff) -> league_time(Kickoff).

php(_In, #{<<"exact">> := true, <<"at">> := At}) ->
    {exact, {utc, At}};
php(_In, #{<<"exact">> := false, <<"at_local">> := At}) ->
    {estimated, league_time(At)}.

league_time(<<Year:4/binary, "-", Month:2/binary, "-", Day:2/binary, " ",
              Hour:2/binary, ":", Minute:2/binary, ":", Second:2/binary>>) ->
    {league_local, {{binary_to_integer(Year), binary_to_integer(Month),
                     binary_to_integer(Day)},
                    {binary_to_integer(Hour), binary_to_integer(Minute),
                     binary_to_integer(Second)}}}.
