-module(league_tests).

-include_lib("eunit/include/eunit.hrl").

-define(AT, {utc, 1724342400}).

a_league_test_() ->
    {foreach, fun open/0, fun league:close/1,
     [fun(League) ->
          {"an accepted command is applied before the reply",
           ?_assertEqual(5000, begin
                                   ok = fund(League, <<"Bo">>, 5000),
                                   league_state:funds(<<"Bo">>, league:state(League))
                               end)}
      end,
      fun(League) ->
          {"a refused command changes nothing",
           ?_assertEqual({{refused, not_the_commissioner}, []},
                         {league:act(League, request(<<"Bo">>, create_draft)),
                          league_state:owner_ledger(league:state(League))})}
      end,
      fun(League) ->
          {"a draft starts in name order until the Commissioner sets one",
           ?_assertMatch(#{draft := #{order := [<<"Ann">>, <<"Bo">>, <<"Cy">>]}},
                         begin
                             ok = league:act(League, request(<<"Cy">>, create_draft)),
                             league:state(League)
                         end)}
      end]}.

a_reopened_league_test() ->
    Directory = directory(),
    {ok, League} = league:open(Directory, opening()),
    ok = fund(League, <<"Bo">>, 5000),
    Before = league:state(League),
    ok = league:close(League),
    {ok, Reopened} = league:open(Directory, opening()),
    After = league:state(Reopened),
    ok = league:close(Reopened),
    ?assertEqual(Before, After).

open() ->
    {ok, League} = league:open(directory(), opening()),
    League.

fund(League, Owner, Units) ->
    league:act(League, request(<<"Cy">>, {confirm_contribution, Owner, Units})).

request(Actor, Command) ->
    #{at => ?AT, actor => Actor, command => Command}.

opening() ->
    {league_opened, #{settings => #{max_teams => 2, stake_units => 700},
                      commissioner => <<"Cy">>,
                      owners => [<<"Cy">>, <<"Bo">>, <<"Ann">>],
                      teams => [<<"Utah">>, <<"Iowa">>]}}.

directory() ->
    Directory = filename:join([os:getenv("TMPDIR", "/tmp"), "league_tests",
                               integer_to_list(erlang:unique_integer([positive]))]),
    _ = file:del_dir_r(Directory),
    Directory.
