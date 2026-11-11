-module(league_replay_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REPLAY_GAME_SECONDS, 12600).

every_league_writes_the_ledgers_the_php_wrote_test_() ->
    [{Trace, {timeout, 120, ?_assertEqual([], disagreements(Trace))}}
     || Trace <- traces()].

traces() ->
    lists:sort([filename:basename(Trace, ".json")
                || Trace <- filelib:wildcard("golden/season/*.json")]).

disagreements(Trace) ->
    {Header, Steps} = trace(Trace),
    Fixture = fixture(maps:get(<<"year">>, Header)),
    [#{<<"event">> := <<"league">>} = Setup | [Funded | _Later] = Played] = Steps,
    {ok, League} = league:open(scratch_directory(Trace), opening(Setup, Fixture)),
    ok = league:observe(League, {schedule_synced, schedule(Fixture)}),
    try
        replay(League, Played, Fixture, #{php_battles => #{},
                                          factory_top_ups => factory_top_ups(Setup, Funded)})
    after
        league:close(League)
    end.

replay(_League, [], _Fixture, _Php) ->
    [];
replay(League, [Step | Later], Fixture, #{php_battles := PhpBattles} = Php) ->
    ok = observe_facts(League, Step, Fixture),
    Battles = maps:merge(PhpBattles, battles_made(Step)),
    Numbered = Php#{php_battles := Battles},
    case step(League, Step, fun(Kind, Number) -> port_number(Kind, Number, Numbered, League)
                            end)
             ++ invariants_hold(League, Step) of
        [] -> replay(League, Later, Fixture, Numbered);
        Disagreement -> Disagreement
    end.

factory_top_ups(#{<<"settings">> := #{<<"initial_contribution_cents">> := BuyIn}},
                #{<<"event">> := <<"setup">>} = Funded) ->
    length([Owner || #{<<"owner">> := Owner, <<"amount">> := Amount} <- ledger(Funded),
                     Amount > binary_to_integer(BuyIn)]).

port_number(battle, Number, #{php_battles := Battles}, League) ->
    port_battle(Number, Battles, League);
port_number(contribution, Number, #{factory_top_ups := TopUps}, League) ->
    case length(maps:get(owner_order, league:state(League))) of
        Owners when Number > Owners -> Number - TopUps;
        _BuyIn -> Number
    end;
port_number(_Kind, Number, _Php, _League) ->
    Number.

invariants_hold(League, Step) ->
    case league_invariants:broken(at(Step), league:state(League)) of
        [] -> [];
        Broken -> [#{step => without_facts(Step), invariants_broken => Broken}]
    end.

battles_made(Step) ->
    #{Number => {Week, Home, Away}
      || #{<<"battle">> := Number, <<"week">> := Week, <<"home">> := Home,
           <<"away">> := Away} <- maps:get(<<"battles">>, Step, [])}.

port_battle(Php, Battles, League) ->
    case Battles of
        #{Php := {Week, Home, Away}} -> same_matchup(Week, Home, Away, Php, League);
        #{} -> Php
    end.

same_matchup(Week, Home, Away, Php, League) ->
    case [Number || #{number := Number, week := W, home_team := H, away_team := A}
                        <- league_state:battles(league:state(League)),
                    {W, H, A} =:= {Week, Home, Away}] of
        [] -> Php;
        Numbers -> lists:max(Numbers)
    end.

observe_facts(League, Step, Fixture) ->
    Polls = [poll(Poll, Fixture) || Poll <- maps:get(<<"polls">>, Step, [])],
    Openings = [{openings_scheduled, [opening(Opening) || Opening <- List]}
                || #{<<"openings">> := List} <- [Step]],
    Boundaries = [{buyback_boundaries, #{narrows_at => {utc, Narrows},
                                         closes_at => {utc, Closes}}}
                  || #{<<"boundaries">> := #{<<"narrows_at">> := Narrows,
                                              <<"closes_at">> := Closes}} <- [Step]],
    lists:foreach(fun(Fact) -> ok = league:observe(League, Fact) end,
                  Polls ++ Openings ++ Boundaries).

opening(#{<<"at">> := At, <<"priced">> := Priced}) ->
    #{at => {utc, At}, priced => Priced}.

step(League, #{<<"event">> := <<"setup">>} = Step, Port) ->
    Before = ledgers(League),
    Funded = [league:act(League, #{at => at(Step), actor => commissioner(League),
                                   command => {confirm_contribution,
                                               buy_in(Owner, League), Units}})
              || #{<<"owner">> := Owner, <<"amount">> := Units} <- ledger(Step)],
    {OwnerRows, HouseRows} = new_rows(Before, ledgers(League)),
    compare(Step, lists:usort(Funded) =:= [ok],
            {[as_the_factory_credits(Row) || Row <- OwnerRows], HouseRows}, Port);
step(_League, #{<<"event">> := <<"clock">>} = Step, Port) ->
    compare(Step, true, {[], []}, Port);
step(League, #{<<"event">> := <<"dashboard">>} = Step, Port) ->
    caught_up(League, Step, Port);
step(League, #{<<"event">> := <<"action">>, <<"status">> := Status} = Step, Port) ->
    Before = ledgers(League),
    Answer = league:act(League, #{at => at(Step), actor => maps:get(<<"owner">>, Step),
                                  command => command(Step, Port)}),
    compare(Step#{<<"answer">> => Answer}, (Answer =:= ok) =:= (Status < 400),
            new_rows(Before, ledgers(League)), Port);
step(League, #{<<"event">> := <<"payouts">>} = Step, Port) ->
    caught_up(League, Step, Port);
step(League, #{<<"event">> := <<"week_end">>} = Step, Port) ->
    caught_up(League, Step, Port)
        ++ same_state(snapshot(Step), port_snapshot(league:state(League)), Step);
step(League, #{<<"event">> := <<"end">>} = Step, _Port) ->
    State = league:state(League),
    same_state((snapshot(Step))#{draft => binary_to_atom(maps:get(<<"draft">>, Step))},
               (port_snapshot(State))#{draft => draft_status(State)}, Step).

buy_in(Owner, League) ->
    league_state:pending_contribution(Owner, league:state(League)).

as_the_factory_credits(#{type := contribution} = Row) -> Row#{related := none};
as_the_factory_credits(Row) -> Row.

caught_up(League, Step, Port) ->
    Before = ledgers(League),
    ok = league:catch_up(League, at(Step)),
    compare(Step, true, new_rows(Before, ledgers(League)), Port).

compare(#{<<"ledger">> := Recorded} = Step, SameAnswer, {OwnerRows, HouseRows}, Port) ->
    Expected = {[row(Row, Port) || #{<<"book">> := <<"owner">>} = Row <- Recorded],
                [row(Row, Port) || #{<<"book">> := <<"house">>} = Row <- Recorded]},
    case SameAnswer andalso Expected =:= {OwnerRows, HouseRows} of
        true -> [];
        false -> [#{step => without_facts(Step), php => Expected,
                    port => {OwnerRows, HouseRows}}]
    end.

same_state(Php, Php, _Step) -> [];
same_state(Php, Port, Step) -> [#{step => without_facts(Step), php => Php, port => Port}].

without_facts(Step) ->
    maps:without([<<"ledger">>, <<"polls">>, <<"openings">>, <<"boundaries">>,
                  <<"teams">>, <<"funds">>, <<"battles">>], Step).

snapshot(#{<<"funds">> := Funds, <<"teams">> := Teams, <<"house">> := House} = Step) ->
    #{funds => Funds, house => House, prize_pool => maps:get(<<"prize_pool">>, Step, null),
      teams => lists:sort([{Team, Owner, Basis}
                           || #{<<"team">> := Team, <<"owner">> := Owner,
                                <<"basis">> := Basis} <- Teams])}.

port_snapshot(#{owners := Owners, teams := Teams} = State) ->
    #{funds => #{Owner => Funds || Owner := #{funds_units := Funds} <- Owners},
      house => league_state:house_balance(State),
      prize_pool => case league_state:prize_pool(State) of
                        not_frozen -> null;
                        Pool -> Pool
                    end,
      teams => lists:sort([{Team, Owner, Basis}
                           || Team := #{owner := Owner, basis_units := Basis} <- Teams])}.

draft_status(#{draft := #{stage := setup}}) -> setup;
draft_status(#{draft := #{stage := {picking, _Slot}}}) -> active;
draft_status(#{draft := #{stage := complete}}) -> complete.

command(#{<<"action">> := Action} = Step, Port) ->
    case action(Action, maps:get(<<"in">>, Step, #{})) of
        {raise_stake, Php, Stake} -> {raise_stake, Port(battle, Php), Stake};
        {answer_raise, Php, Answer} -> {answer_raise, Port(battle, Php), Answer};
        {Contribution, Php} when Contribution =:= cancel_fund_request;
                                 Contribution =:= reject_contribution;
                                 Contribution =:= reverse_contribution ->
            {Contribution, Port(contribution, Php)};
        {confirm_contribution, Php, Amount} ->
            {confirm_contribution, Port(contribution, Php), Amount};
        Command -> Command
    end.

action(<<"settle_season">>, _In) -> settle_season;
action(<<"request_additional_funds">>, In) ->
    {request_funds, units(maps:get(<<"amount">>, In))};
action(<<"cancel_fund_request">>, In) ->
    {cancel_fund_request, number(In, <<"contribution_id">>)};
action(<<"confirm_contribution">>, #{<<"amount">> := Amount} = In) ->
    {confirm_contribution, number(In, <<"contribution_id">>), units(Amount)};
action(<<"confirm_contribution">>, In) ->
    {confirm_contribution, number(In, <<"contribution_id">>), as_requested};
action(<<"reject_contribution">>, In) ->
    {reject_contribution, number(In, <<"contribution_id">>)};
action(<<"reverse_contribution">>, In) ->
    {reverse_contribution, number(In, <<"contribution_id">>)};
action(<<"adjust_available_funds">>, In) ->
    {adjust_funds, maps:get(<<"owner_id">>, In), units(maps:get(<<"amount">>, In)),
     maps:get(<<"reason">>, In)};
action(<<"create_draft">>, _In) -> create_draft;
action(<<"set_draft_order">>, In) -> {set_draft_order, maps:get(<<"owner_ids">>, In)};
action(<<"start_draft">>, _In) -> start_draft;
action(<<"draft_select">>, In) -> {draft_select, team(In)};
action(<<"draft_pass">>, _In) -> draft_pass;
action(<<"undo_pick">>, _In) -> undo_pick;
action(<<"submit_bid">>, In) ->
    {order, {bid, units(maps:get(<<"amount">>, In))}, team(In)};
action(<<"add_free_team">>, In) -> {order, add, team(In)};
action(<<"drop_team">>, In) -> {order, drop, team(In)};
action(<<"submit_drop_order">>, In) -> {order, conditional_drop, team(In)};
action(<<"sale_to_house">>, In) -> {order, sale, team(In)};
action(<<"cancel_order">>, In) -> {cancel_order, number(In, <<"order_id">>)};
action(<<"reorder_bid">>, In) ->
    Direction = binary_to_atom(maps:get(<<"direction">>, In)),
    {reorder_bid, number(In, <<"order_id">>), Direction};
action(<<"propose_trade">>, In) ->
    {propose_trade, #{to => maps:get(<<"to_owner_id">>, In),
                      sending => team_or_none(maps:get(<<"team_out_id">>, In)),
                      receiving => team_or_none(maps:get(<<"team_in_id">>, In)),
                      cash_units => units(maps:get(<<"cash">>, In)),
                      paid_by => paid_by(maps:get(<<"cash_direction">>, In))}};
action(<<"confirm_trade">>, In) -> {confirm_trade, number(In, <<"tx_id">>)};
action(<<"cancel_trade">>, In) -> {cancel_trade, number(In, <<"tx_id">>)};
action(<<"raise_battle_stake">>, In) ->
    {raise_stake, number(In, <<"battle_id">>), units(maps:get(<<"stake">>, In))};
action(<<"respond_battle_stake">>, In) ->
    {answer_raise, number(In, <<"battle_id">>), accepted(maps:get(<<"accept">>, In))}.

team(#{<<"team_id">> := null}) -> <<>>;
team(#{<<"team_id">> := Team}) -> Team.

team_or_none(null) -> no_team;
team_or_none(Team) -> Team.

number(In, Key) ->
    case maps:get(Key, In) of
        Number when is_integer(Number) -> Number;
        _NoSuchRecord -> 0
    end.

paid_by(<<"i_pay">>) -> me;
paid_by(_TheyPay) -> them.

accepted(true) -> accept;
accepted(false) -> decline.

units(<<"-", Dollars/binary>>) ->
    -units(Dollars);
units(Dollars) ->
    [Whole | Cents] = binary:split(Dollars, <<".">>),
    binary_to_integer(Whole) * 100 + cents(Cents).

cents([]) -> 0;
cents([<<Tens>>]) -> (Tens - $0) * 10;
cents([<<Tens, Ones>>]) -> (Tens - $0) * 10 + (Ones - $0).

ledgers(League) ->
    State = league:state(League),
    {league_state:owner_ledger(State), league_state:house_ledger(State)}.

new_rows({OwnerBefore, HouseBefore}, {OwnerAfter, HouseAfter}) ->
    {lists:nthtail(length(OwnerBefore), OwnerAfter),
     lists:nthtail(length(HouseBefore), HouseAfter)}.

row(#{<<"entry">> := Entry, <<"owner">> := Owner, <<"type">> := Type,
      <<"amount">> := Amount, <<"balance_after">> := After, <<"related">> := Related} = Row,
    Port) ->
    maps:merge(#{entry => Entry, owner => none_if_null(Owner), type => binary_to_atom(Type),
                 amount_units => Amount, balance_after_units => After,
                 related => related(Related, Port)},
               #{reason => Reason || <<"reason">> := Reason <- maps:iterator(Row)}).

none_if_null(null) -> none;
none_if_null(Owner) -> Owner.

related(null, _Port) -> none;
related([Kind, Php], Port) ->
    Numbered = binary_to_atom(Kind),
    {Numbered, Port(Numbered, Php)}.

at(#{<<"at">> := At}) -> {utc, At}.

ledger(#{<<"ledger">> := Rows}) -> Rows.

commissioner(League) ->
    maps:get(commissioner, league:state(League)).

opening(#{<<"settings">> := Settings, <<"owners">> := Owners}, #{<<"teams">> := Teams}) ->
    Names = [Owner || #{<<"owner">> := Owner} <- Owners],
    {league_opened, #{settings => settings(Settings), commissioner => hd(Names),
                      owners => Names,
                      teams => [School || #{<<"school">> := School} <- Teams]}}.

settings(#{<<"max_teams">> := MaxTeams, <<"battle_stake_cents">> := Stake,
           <<"battle_house_pct">> := HousePercent,
           <<"buyback_narrows_on">> := NarrowsOn, <<"buyback_closes_on">> := ClosesOn,
           <<"initial_contribution_cents">> := BuyIn,
           <<"additional_contributions_enabled">> := TopUps}) ->
    #{max_teams => binary_to_integer(MaxTeams), stake_units => binary_to_integer(Stake),
      buy_in_units => binary_to_integer(BuyIn), top_ups_enabled => TopUps =:= <<"1">>,
      house_fee_basis_points => units(HousePercent),
      buyback_narrows_on => league_date(NarrowsOn),
      buyback_closes_on => league_date(ClosesOn)}.

league_date(<<Year:4/binary, "-", Month:2/binary, "-", Day:2/binary>>) ->
    {league_local, {binary_to_integer(Year), binary_to_integer(Month),
                    binary_to_integer(Day)}}.

schedule(#{<<"games">> := Weeks} = Fixture) ->
    [game(binary_to_integer(Week), regular, Game)
     || Week := Games <- Weeks, Game <- Games]
        ++ [(game(1, postseason, Game))#{notes => Notes}
            || #{<<"notes">> := Notes} = Game <- maps:get(<<"playoff">>, Fixture, [])].

game(Week, SeasonType, #{<<"home">> := Home, <<"away">> := Away, <<"kickoff">> := Kickoff,
                         <<"home_points">> := HomePoints,
                         <<"away_points">> := AwayPoints} = Game) ->
    #{week => Week, season_type => SeasonType, home_team => Home, away_team => Away,
      kickoff => {utc, Kickoff}, line => line(maps:get(<<"spread">>, Game, null)),
      final_at => {utc, Kickoff + ?REPLAY_GAME_SECONDS},
      home_points => HomePoints, away_points => AwayPoints}.

line(null) -> no_line_quoted;
line(Spread) -> {home_spread_tenths, round(Spread * 10)}.

poll(#{<<"week">> := Week, <<"poll">> := Poll}, Fixture) ->
    Ranked = maps:get(integer_to_binary(Week), maps:get(rankings_key(Poll), Fixture)),
    {poll_applied, #{week => Week, poll => binary_to_atom(string:lowercase(Poll)),
                     ranks => #{School => binary_to_integer(Rank)
                                || Rank := School <- Ranked}}}.

rankings_key(<<"AP">>) -> <<"rankings">>;
rankings_key(<<"CFP">>) -> <<"rankings_cfp">>.

trace(Name) ->
    {ok, Recorded} = file:read_file(filename:join(["golden", "season", Name ++ ".json"])),
    [Header | Steps] = binary:split(Recorded, <<"\n">>, [global, trim_all]),
    {json:decode(Header), [json:decode(Step) || Step <- Steps]}.

fixture(Year) ->
    Name = "season-" ++ integer_to_list(Year) ++ ".json",
    Fixtures = filename:join(["reference", "pp26dev", "setup", "fixtures"]),
    {ok, Season} = file:read_file(filename:join(Fixtures, Name)),
    json:decode(Season).

scratch_directory(Trace) ->
    Directory = filename:join([os:getenv("TMPDIR", "/tmp"), "league_replay", Trace]),
    _ = file:del_dir_r(Directory),
    Directory.
