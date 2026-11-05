-module(football_battle_reserve_golden_tests).

-include_lib("eunit/include/eunit.hrl").

every_recorded_reserve_is_what_the_php_required_test() ->
    ?assertEqual([], golden:disagreements("reserve_for", fun required/1, fun php/2)).

every_recorded_headroom_is_what_the_php_left_test() ->
    ?assertEqual([], golden:disagreements("decide_reserve_headroom",
                                          fun headroom/1, fun php_headroom/2)).

every_recorded_margin_call_is_what_the_php_called_test() ->
    ?assertEqual([], golden:disagreements("decide_margin_call",
                                          fun margin_call/1, fun php_margin_call/2)).

required(#{<<"teams">> := Teams, <<"stakeCents">> := Stake,
           <<"extraGames">> := ExtraGames, <<"battlesPossible">> := BattlesPossible}) ->
    football_battle_reserve:required_units(#{teams_held => Teams,
                                             extra_games_this_week => ExtraGames,
                                             stake_units => Stake,
                                             battle_season => season(BattlesPossible)}).

php(_In, Required) ->
    Required.

headroom(#{<<"s">> := #{<<"cash_out">> := CashOut, <<"teams_gained">> := TeamsGained,
                        <<"max_teams">> := MaxTeams} = Holding}) ->
    football_battle_reserve:headroom((holding(Holding))#{cash_out_units => CashOut,
                                                         teams_gained => TeamsGained,
                                                         max_teams => MaxTeams}).

php_headroom(_In, #{<<"ok">> := Fits, <<"teams_after">> := TeamsAfter,
                    <<"reserve">> := Reserve, <<"escrow">> := EscrowCredit,
                    <<"held_cents">> := HeldBack, <<"headroom">> := Headroom}) ->
    {fits(Fits), #{teams_after => TeamsAfter, reserve_units => Reserve,
                   escrow_credit_units => EscrowCredit, held_back_units => HeldBack,
                   headroom_units => Headroom}}.

fits(true) -> fits;
fits(false) -> spends_into_the_reserve.

margin_call(#{<<"s">> := Holding}) ->
    football_battle_reserve:margin_call(holding(Holding)).

php_margin_call(_In, #{<<"in_call">> := false, <<"required">> := Required}) ->
    {in_good_standing, #{required_units => Required}};
php_margin_call(_In, #{<<"in_call">> := true, <<"required">> := Required,
                       <<"short">> := Short}) ->
    {in_margin_call, #{required_units => Required, short_units => Short}}.

holding(#{<<"funds">> := Funds, <<"escrow">> := Escrow, <<"teams_held">> := TeamsHeld,
          <<"extra_games">> := ExtraGames, <<"stake">> := Stake,
          <<"battles_possible">> := BattlesPossible}) ->
    #{funds_units => Funds, escrow_units => Escrow, teams_held => TeamsHeld,
      extra_games_this_week => ExtraGames, stake_units => Stake,
      battle_season => season(BattlesPossible)}.

season(true) -> battles_being_created;
season(false) -> battles_over.
