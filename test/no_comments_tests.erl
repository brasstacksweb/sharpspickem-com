-module(no_comments_tests).

-include_lib("eunit/include/eunit.hrl").

every_source_file_is_free_of_comments_test_() ->
    [{File, ?_assertEqual([], comment_lines(File))} || File <- source_files()].

every_source_file_is_free_of_doc_attributes_test_() ->
    [{File, ?_assertEqual([], doc_attribute_lines(File))} || File <- source_files()].

the_scan_finds_this_test_file_test() ->
    ?assert(lists:member("test/no_comments_tests.erl", source_files())).

the_scan_finds_the_files_inside_each_app_test_() ->
    [?_assert(lists:member(File, source_files()))
     || File <- ["apps/sharps_rules/src/sharps_rules.app.src",
                 "apps/sharps_league/src/sharps_league.app.src",
                 "apps/sharps_web/src/sharps_web.app.src",
                 "apps/sharps_rules/src/football_battle_result.erl",
                 "apps/sharps_rules/test/football_battle_result_tests.erl"]].

source_files() ->
    {ok, ProjectRoot} = file:get_cwd(),
    true = filelib:is_regular(filename:join(ProjectRoot, "rebar.config")),
    Patterns = ["rebar.config", "test/**/*.erl", "test/**/*.hrl",
                "apps/*/src/**/*.erl", "apps/*/src/**/*.hrl", "apps/*/src/**/*.app.src",
                "apps/*/include/**/*.hrl",
                "apps/*/test/**/*.erl", "apps/*/test/**/*.hrl"],
    Matches = [filelib:wildcard(Pattern, ProjectRoot) || Pattern <- Patterns],
    lists:usort(lists:append(Matches)).

comment_lines(File) ->
    [erl_anno:line(Anno) || {comment, Anno, _Text} <- tokens(File)].

doc_attribute_lines(File) ->
    attribute_starts_named([doc, moduledoc], [{dot, erl_anno:new(0)} | tokens(File)]).

attribute_starts_named(Names, [{dot, _}, {'-', Anno}, {atom, _, Name} | Rest]) ->
    case lists:member(Name, Names) of
        true -> [erl_anno:line(Anno) | attribute_starts_named(Names, Rest)];
        false -> attribute_starts_named(Names, Rest)
    end;
attribute_starts_named(Names, [_Token | Rest]) ->
    attribute_starts_named(Names, Rest);
attribute_starts_named(_Names, []) ->
    [].

tokens(File) ->
    {ok, Bytes} = file:read_file(File),
    Text = unicode:characters_to_list(Bytes),
    {ok, Tokens, _EndLocation} = erl_scan:string(Text, 1, [return_comments]),
    Tokens.
