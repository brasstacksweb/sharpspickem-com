-module(football_battle_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, {utc, 1000000}).

matchups_test_() ->
    Owners = #{<<"Utah">> => <<"Ann">>, <<"Iowa">> => <<"Bo">>, <<"Ohio">> => <<"Ann">>,
               <<"Duke">> => <<"Cy">>},
    [
        {"§11: two owners' teams meeting this week make a Battle",
         ?_assertMatch([#{home_team := <<"Utah">>, away_team := <<"Iowa">>,
                          home_owner := <<"Ann">>, away_owner := <<"Bo">>}],
                       matchups([game(1, <<"Utah">>, <<"Iowa">>, 3600)], Owners, []))},
        {"one owner on both sides is no Battle",
         ?_assertEqual([], matchups([game(1, <<"Utah">>, <<"Ohio">>, 3600)], Owners,
                                    []))},
        {"a House team on either side is no Battle",
         ?_assertEqual([], matchups([game(1, <<"Utah">>, <<"Rice">>, 3600)], Owners,
                                    []))},
        {"a game already kicked off is too late; catches >= for >",
         ?_assertEqual([], matchups([game(1, <<"Utah">>, <<"Iowa">>, 0)], Owners, []))},
        {"only this week's games; catches creating next week's early",
         ?_assertMatch([#{week := 1}],
                       matchups([game(1, <<"Utah">>, <<"Iowa">>, 3600),
                                 game(2, <<"Duke">>, <<"Iowa">>, 7200)], Owners, []))},
        {"a Battle already made is not made again, whichever side is home",
         ?_assertEqual([], matchups([game(1, <<"Utah">>, <<"Iowa">>, 3600)], Owners,
                                    [{1, <<"Iowa">>, <<"Utah">>}]))}
    ].

binding_test_() ->
    [
        {"open until 30 minutes before kickoff",
         ?_assertEqual(not_yet, bind(binding(1801, {700, 700})))},
        {"§11: the line freezes 30 minutes before kickoff and the stakes are taken",
         ?_assertEqual(bound, bind(binding(1800, {700, 700})))},
        {"no stake is taken from an owner who cannot cover it; catches > for >=",
         ?_assertEqual({rejected, could_not_cover_the_stake},
                       bind(binding(1800, {700, 699})))},
        {"a team that changed hands dissolves the Battle, frozen or not",
         ?_assertEqual(dissolved,
                       football_battle:bind((binding(9999, {700, 700}))#{
                                                holders_now := {<<"Ann">>, house}},
                                            owners_changed))}
    ].

raising_test_() ->
    [
        {"either owner may offer a higher stake",
         ?_assertEqual({offered, 900}, raise(<<"Bo">>, #{}))},
        {"nobody else may",
         ?_assertEqual({refused, not_in_this_battle}, raise(<<"Cy">>, #{}))},
        {"§11: not while in Margin Call",
         ?_assertEqual({refused, in_margin_call},
                       raise(<<"Ann">>, #{margin_call => in_margin_call}))},
        {"a raise must be more than the stake; catches >= for >",
         ?_assertEqual({refused, not_more_than_the_stake},
                       raise(<<"Ann">>, #{stake_units => 700}))},
        {"not after kickoff",
         ?_assertEqual({refused, kicked_off}, raise(<<"Ann">>, #{kicked_off => true}))},
        {"one raise at a time",
         ?_assertEqual({refused, a_raise_is_waiting},
                       raise(<<"Ann">>, #{battle => offered(<<"Bo">>, 800)}))}
    ].

answering_test_() ->
    Offered = offered(<<"Ann">>, 900),
    [
        {"the other owner accepts, and both pay the difference once the stakes are taken",
         ?_assertEqual({raised, 900, 200},
                       answer(<<"Bo">>, accept,
                              #{battle => Offered#{status := accepted}}))},
        {"before the line freezes nothing has been taken, so nothing is paid",
         ?_assertEqual({raised, 900, 0}, answer(<<"Bo">>, accept, #{battle => Offered}))},
        {"the owner who raised cannot answer themselves",
         ?_assertEqual({refused, only_the_other_owner}, answer(<<"Ann">>, accept,
                                                               #{battle => Offered}))},
        {"a decline needs no funds and no clock",
         ?_assertEqual(declined, answer(<<"Bo">>, decline, #{battle => Offered,
                                                            kicked_off => true}))},
        {"both owners must be able to pay the difference",
         ?_assertEqual({refused, both_owners_cannot_cover_the_raise},
                       answer(<<"Bo">>, accept, #{battle => Offered#{status := accepted},
                                                  funds_units => {1000, 199}}))}
    ].

matchups(Games, Owners, Already) ->
    football_battle:matchups(Games, Owners, #{now => ?NOW, already => Already}).

game(Week, Home, Away, SecondsAway) ->
    {utc, Now} = ?NOW,
    #{week => Week, home_team => Home, away_team => Away,
      kickoff => {utc, Now + SecondsAway}, line => no_line_quoted}.

binding(SecondsToKickoff, Funds) ->
    {utc, Now} = ?NOW,
    #{home_owner => <<"Ann">>, away_owner => <<"Bo">>,
      holders_now => {<<"Ann">>, <<"Bo">>},
      kickoff => {utc, Now + SecondsToKickoff}, now => ?NOW, stake_units => 700,
      funds_units => Funds}.

bind(Binding) ->
    football_battle:bind(Binding, lines_frozen).

offered(By, Stake) ->
    (battle())#{raise := {offered, By, Stake}}.

battle() ->
    #{home_owner => <<"Ann">>, away_owner => <<"Bo">>, stake_units => 700, raise => none,
      status => pending}.

raise(Owner, Overrides) ->
    football_battle:raise(Owner, maps:merge(#{battle => battle(), stake_units => 900,
                                              margin_call => in_good_standing,
                                              kicked_off => false,
                                              headroom => {fits, #{}}}, Overrides)).

answer(Owner, Answer, Overrides) ->
    football_battle:answer_raise(Owner, Answer,
                                 maps:merge(#{kicked_off => false,
                                              funds_units => {1000, 1000},
                                              headroom => {{fits, #{}}, {fits, #{}}}},
                                            Overrides)).
