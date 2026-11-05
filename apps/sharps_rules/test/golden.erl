-module(golden).

-export([disagreements/3]).

disagreements(Decider, Port, Php) ->
    [#{in => In, php => Expected, port => Got}
     || #{<<"in">> := In, <<"out">> := Out} <- cases(Decider),
        Expected <- [Php(In, Out)],
        Got <- [Port(In)],
        Got =/= Expected].

cases(Decider) ->
    {ok, Recorded} = file:read_file(filename:join("golden", Decider ++ ".json")),
    #{<<"cases">> := Cases} = json:decode(Recorded),
    Cases.
