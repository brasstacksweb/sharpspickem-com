-module(league_invariants_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, {utc, 1000000}).

a_healthy_league_breaks_nothing_test() ->
    ?assertEqual([], league_invariants:broken(?NOW, healthy())).

money_test_() ->
    [{"the House paying out more than it holds",
      ?_assertEqual([house_negative],
                    broken(with(healthy(), [{team_sold, #{owner => <<"Bo">>,
                                                          team => <<"Navy">>,
                                                          price_units => 5000}}])))},
     {"funds that moved without a ledger row",
      ?_assertEqual([conservation_broken, funds_off_the_ledger],
                    broken(with_funds(<<"Ann">>, 1, healthy())))},
     {"a row whose amount was edited after the fact",
      ?_assertEqual([chain_broken, money_created_or_destroyed],
                    broken(with_owner_row(3, #{amount_units => -701}, healthy())))},
     {"a row renumbered",
      ?_assertEqual([chain_broken],
                    broken(with_owner_row(3, #{entry => 9}, healthy())))},
     {"a ledger type nobody classified",
      ?_assertEqual([unclassified_ledger_type],
                    broken(with_owner_row(3, #{type => mystery}, healthy())))},
     {"the House crediting itself money no one paid",
      ?_assertEqual([conservation_broken, money_created_or_destroyed],
                    broken(with_house_fee_from_nowhere(healthy())))}].

ownership_test_() ->
    [{"more teams than the maximum",
      ?_assertEqual([over_max_teams],
                    broken(with(healthy(), [added(<<"Ann">>, Team)
                                            || Team <- [<<"Ohio State">>, <<"Army">>,
                                                        <<"Rice">>, <<"Tulane">>,
                                                        <<"Duke">>]])))},
     {"an owned team that lost its cost basis",
      ?_assertEqual([basis_mismatch], broken(without_basis(<<"Utah">>, healthy())))}].

battles_test_() ->
    [{"a Battle refunded with no refund paid",
      ?_assertEqual([stakes_not_released],
                    broken(with_status(1, refunded, healthy())))}].

reserve_test_() ->
    [{"§11: spending below a stake per team breaks the reserve",
      ?_assertEqual([under_the_reserve],
                    broken(buying(<<"Ann">>, 9020, healthy())))},
     {"§11: unless losing Battles explains it: Bo lost a 700 stake",
      ?_assertEqual([], broken(buying(<<"Bo">>, 7200, healthy())))},
     {"and only as far as the stakes lost; catches licensing a shortfall beyond them",
      ?_assertEqual([under_the_reserve], broken(buying(<<"Bo">>, 7201, healthy())))},
     {"once no Battle can be created the reserve is released",
      ?_assertEqual([], broken(with(buying(<<"Ann">>, 9020, healthy()),
                                    [{schedule_synced, [played()]}])))}].

healthy() ->
    Opened = league_state:new(
               {league_opened,
                #{settings => #{max_teams => 5, stake_units => 700,
                                house_fee_basis_points => 2000},
                  commissioner => <<"Ann">>, owners => [<<"Ann">>, <<"Bo">>],
                  teams => [<<"Utah">>, <<"Navy">>, <<"Ohio State">>, <<"Army">>,
                            <<"Rice">>, <<"Tulane">>, <<"Duke">>]}}),
    with(Opened,
         [{contribution_confirmed, #{owner => <<"Ann">>, units => 10000}},
          {contribution_confirmed, #{owner => <<"Bo">>, units => 10000}},
          {team_bought, #{owner => <<"Ann">>, team => <<"Utah">>, price_units => 700}},
          {team_bought, #{owner => <<"Bo">>, team => <<"Navy">>, price_units => 700}},
          {battle_created, battle(1)},
          {battle_bound, 1},
          {battle_settled, 1, #{winner => <<"Ann">>, payout_units => 1120,
                                house_fee_units => 280}},
          {battle_created, battle(2)},
          {battle_bound, 2}]).

battle(Number) ->
    #{number => Number, week => Number, home_team => <<"Utah">>, away_team => <<"Navy">>,
      home_owner => <<"Ann">>, away_owner => <<"Bo">>, line => no_line_quoted,
      stake_units => 700, house_fee_basis_points => 2000, status => pending,
      raise => none}.

played() ->
    #{week => 1, season_type => regular, home_team => <<"Utah">>, away_team => <<"Navy">>,
      kickoff => {utc, 1}, line => no_line_quoted, final_at => {utc, 2},
      home_points => 0, away_points => 0}.

with(State, Events) ->
    lists:foldl(fun league_state:apply_event/2, State, Events).

buying(Owner, Price, State) ->
    with(State, [{team_bought, #{owner => Owner, team => <<"Ohio State">>,
                                 price_units => Price}},
                 added(Owner, <<"Army">>)]).

added(Owner, Team) ->
    {team_added, #{owner => Owner, team => Team}}.

with_funds(Owner, Extra, #{owners := Owners} = State) ->
    #{Owner := #{funds_units := Funds} = Account} = Owners,
    State#{owners := Owners#{Owner := Account#{funds_units := Funds + Extra}}}.

with_owner_row(Entry, Changes, #{owner_ledger := NewestFirst} = State) ->
    State#{owner_ledger := [changed(Entry, Changes, Row) || Row <- NewestFirst]}.

changed(Entry, Changes, #{entry := Entry} = Row) -> maps:merge(Row, Changes);
changed(_Entry, _Changes, Row) -> Row.

with_house_fee_from_nowhere(#{house_ledger := [#{entry := Last,
                                                  balance_after_units := Balance} | _]
                                             = NewestFirst} = State) ->
    State#{house_ledger := [#{entry => Last + 1, owner => none, type => battle,
                              amount_units => 100, balance_after_units => Balance + 100,
                              related => {battle, 1}} | NewestFirst]}.

without_basis(Team, #{teams := Teams} = State) ->
    #{Team := Held} = Teams,
    State#{teams := Teams#{Team := maps:remove(basis_units, Held)}}.

with_status(Number, Status, #{battles := Battles} = State) ->
    #{Number := Battle} = Battles,
    State#{battles := Battles#{Number := Battle#{status := Status}}}.

broken(State) ->
    lists:usort([Kind || Violation <- league_invariants:broken(?NOW, State),
                         Kind <- [element(1, Violation)]]).
