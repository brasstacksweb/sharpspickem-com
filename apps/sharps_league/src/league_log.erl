-module(league_log).

-export([open/2, append/2, events/1, close/1]).

-export_type([log/0]).

-opaque log() :: {league_log, term()}.

-spec open(file:filename(), term()) -> {ok, log()}.
open(Directory, League) ->
    ok = filelib:ensure_dir(filename:join(Directory, "events")),
    Name = {league_log, League},
    case disk_log:open([{name, Name}, {file, filename:join(Directory, "events")},
                        {type, halt}, {format, internal}]) of
        {ok, Name} -> {ok, Name};
        {repaired, Name, _Recovered, _BadBytes} -> {ok, Name}
    end.

-spec append(log(), [league_state:event()]) -> ok.
append(Log, Events) ->
    ok = disk_log:log_terms(Log, Events),
    ok = disk_log:sync(Log).

-spec events(log()) -> [league_state:event()].
events(Log) ->
    lists:append(chunks(Log, start)).

chunks(Log, Continuation) ->
    case disk_log:chunk(Log, Continuation) of
        eof -> [];
        {NextContinuation, Events} -> [Events | chunks(Log, NextContinuation)]
    end.

-spec close(log()) -> ok.
close(Log) ->
    ok = disk_log:close(Log).
