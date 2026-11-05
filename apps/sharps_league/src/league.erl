-module(league).

-behaviour(gen_server).

-export([open/2, act/2, observe/2, catch_up/2, state/1, close/1]).

-export([init/1, handle_call/3, handle_cast/2]).

-type league() :: #{log := league_log:log(), state := league_state:state()}.

-type call() :: {act, league_commands:request()}
              | {observe, league_state:event()}
              | {catch_up, {utc, integer()}}
              | state.

-spec open(file:filename(), league_state:event()) -> {ok, pid()}.
open(Directory, Opening) ->
    {ok, League} = gen_server:start_link(?MODULE, {Directory, Opening}, []),
    {ok, League}.

-spec act(pid(), league_commands:request()) -> ok | {refused, term()}.
act(League, Request) ->
    gen_server:call(League, {act, Request}).

-spec observe(pid(), league_state:event()) -> ok.
observe(League, Fact) ->
    gen_server:call(League, {observe, Fact}).

-spec catch_up(pid(), {utc, integer()}) -> ok.
catch_up(League, Now) ->
    gen_server:call(League, {catch_up, Now}).

-spec state(pid()) -> league_state:state().
state(League) ->
    gen_server:call(League, state).

-spec close(pid()) -> ok.
close(League) ->
    gen_server:stop(League).

-spec init({file:filename(), league_state:event()}) -> {ok, league()}.
init({Directory, {league_opened, #{}} = Opening}) ->
    {ok, Log} = league_log:open(Directory, self()),
    History = case league_log:events(Log) of
                  [] -> ok = league_log:append(Log, [Opening]), [Opening];
                  Recorded -> Recorded
              end,
    [Opened | Since] = History,
    {ok, #{log => Log, state => lists:foldl(fun league_state:apply_event/2,
                                            league_state:new(Opened), Since)}}.

-spec handle_call(call(), gen_server:from(), league()) -> {reply, term(), league()}.
handle_call({act, Request}, _From, #{state := State} = League) ->
    case league_commands:decide(Request, State) of
        {ok, Events} -> {reply, ok, record(Events, League)};
        Refused -> {reply, Refused, League}
    end;
handle_call({catch_up, Now}, _From, #{state := State} = League) ->
    {reply, ok, record(league_catch_up:catch_up(Now, State), League)};
handle_call({observe, Fact}, _From, League) ->
    {reply, ok, record([Fact], League)};
handle_call(state, _From, #{state := State} = League) ->
    {reply, State, League}.

-spec handle_cast(term(), league()) -> {noreply, league()}.
handle_cast(_Ignored, League) ->
    {noreply, League}.

record(Events, #{log := Log, state := State} = League) ->
    ok = league_log:append(Log, Events),
    League#{state := lists:foldl(fun league_state:apply_event/2, State, Events)}.
