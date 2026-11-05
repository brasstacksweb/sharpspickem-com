-module(layering_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APPS, [sharps_rules, sharps_league, sharps_web]).

-define(PURE_MODULES, [lists, maps, proplists, ordsets, orddict, sets, gb_sets, gb_trees,
                       string, binary, unicode, math]).

-define(PURE_FUNCTIONS, [{calendar, date_to_gregorian_days, 1},
                         {calendar, date_to_gregorian_days, 3},
                         {calendar, gregorian_days_to_date, 1},
                         {calendar, day_of_the_week, 1},
                         {calendar, last_day_of_the_month, 2},
                         {calendar, valid_date, 1}]).

-define(IMPURE_GUARD_BIFS, [{self, 0}, {node, 0}, {node, 1}]).

each_app_calls_only_itself_and_the_apps_it_declares_test_() ->
    [{atom_to_list(App), ?_assertEqual([], undeclared_calls(App))} || App <- ?APPS].

the_rules_call_nothing_with_side_effects_test() ->
    ?assertEqual([], [Call || {_Caller, Callee} = Call <- external_calls(sharps_rules),
                              not is_another_rule(Callee), not is_pure(Callee)]).

a_rule_may_call_another_rule_test_() ->
    [{"a rule is pure because this file checks it",
      ?_assert(is_another_rule({football_battle_result, decide, 2}))},
     {"the league is not a rule",
      ?_assertNot(is_another_rule({league_server, call, 2}))}].

the_purity_check_rejects_the_clock_and_messages_test_() ->
    [{"reading the clock", ?_assertNot(is_pure({erlang, system_time, 1}))},
     {"sending a message", ?_assertNot(is_pure({erlang, send, 2}))},
     {"spawning a process", ?_assertNot(is_pure({erlang, spawn, 1}))},
     {"asking who we are", ?_assertNot(is_pure({erlang, self, 0}))},
     {"reading a file", ?_assertNot(is_pure({file, read_file, 1}))},
     {"calling the league", ?_assertNot(is_pure({league_server, call, 2}))},
     {"arithmetic is pure", ?_assert(is_pure({erlang, 'div', 2}))},
     {"list functions are pure", ?_assert(is_pure({lists, map, 2}))},
     {"counting days is pure", ?_assert(is_pure({calendar, date_to_gregorian_days, 1}))},
     {"the calendar's clock is not",
      ?_assertNot(is_pure({calendar, universal_time, 0}))}].

the_layering_check_rejects_the_rules_calling_the_league_test() ->
    ?assertNot(lists:member(sharps_league, allowed_apps(sharps_rules))).

undeclared_calls(App) ->
    Allowed = allowed_apps(App),
    [Call || {_Caller, {Module, _, _}} = Call <- external_calls(App),
             not lists:member(owning_app(Module), Allowed)].

allowed_apps(App) ->
    ok = load(App),
    {ok, Declared} = application:get_key(App, applications),
    [App, erts | Declared].

load(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok
    end.

external_calls(App) ->
    {ok, Xref} = xref:start([{xref_mode, functions}]),
    try
        ok = xref:set_default(Xref, [{verbose, false}, {warnings, false},
                                     {builtins, true}]),
        {ok, App} = xref:add_application(Xref, code:lib_dir(App)),
        {ok, Calls} = xref:q(Xref, "XC | " ++ atom_to_list(App) ++ " : App"),
        Calls
    after
        xref:stop(Xref)
    end.

owning_app(Module) ->
    case code:which(Module) of
        preloaded -> erts;
        non_existing -> {missing_module, Module};
        Beam -> app_installed_at(filename:dirname(filename:dirname(Beam)))
    end.

app_installed_at(AppDirectory) ->
    app_named_by_directory(filename:basename(AppDirectory)).

app_named_by_directory(Directory) ->
    [Name | _Version] = string:split(Directory, "-"),
    list_to_atom(Name).

is_another_rule({Module, _Function, _Arity}) ->
    owning_app(Module) =:= sharps_rules.

is_pure({erlang, Function, Arity}) ->
    is_pure_erlang_function(Function, Arity)
        andalso not lists:member({Function, Arity}, ?IMPURE_GUARD_BIFS);
is_pure({Module, _Function, _Arity} = Callee) ->
    lists:member(Module, ?PURE_MODULES) orelse lists:member(Callee, ?PURE_FUNCTIONS).

is_pure_erlang_function(error, Arity) when Arity >= 1, Arity =< 3 ->
    true;
is_pure_erlang_function(Function, Arity) ->
    erl_internal:arith_op(Function, Arity)
        orelse erl_internal:comp_op(Function, Arity)
        orelse erl_internal:bool_op(Function, Arity)
        orelse erl_internal:list_op(Function, Arity)
        orelse erl_internal:guard_bif(Function, Arity).
