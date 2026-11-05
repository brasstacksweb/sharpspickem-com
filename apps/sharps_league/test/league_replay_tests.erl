-module(league_replay_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DRAFT_NIGHT, [<<"create_draft">>, <<"set_draft_order">>, <<"start_draft">>,
                      <<"draft_select">>, <<"draft_pass">>, <<"undo_pick">>]).

draft_night_writes_the_ledgers_the_php_wrote_test_() ->
    [{Trace, ?_assertEqual([], disagreements(Trace))} || Trace <- traces()].

traces() ->
    lists:sort([filename:basename(Trace, ".json")
                || Trace <- filelib:wildcard("golden/season/*.json")]).

disagreements(Trace) ->
    {Header, Steps} = trace(Trace),
    Fixture = fixture(maps:get(<<"year">>, Header)),
    Directory = scratch_directory(Trace),
    [#{<<"event">> := <<"league">>} = Setup | Played] = Steps,
    {ok, League} = league:open(Directory, opening(Setup, Fixture)),
    ok = league:observe(League, {schedule_synced, schedule(Fixture)}),
    {DraftNight, Rest} = lists:splitwith(fun on_draft_night/1, Played),
    try
        lists:append([step(League, Step, Fixture) || Step <- DraftNight])
            ++ the_end(League, Rest)
    after
        league:close(League)
    end.

on_draft_night(#{<<"event">> := <<"setup">>}) -> true;
on_draft_night(#{<<"action">> := Action}) -> lists:member(Action, ?DRAFT_NIGHT);
on_draft_night(#{}) -> false.

the_end(League, [#{<<"event">> := <<"end">>} = End]) ->
    Php = end_state(End),
    case port_end_state(league:state(League)) of
        Php -> [];
        Port -> [#{step => the_end, php => Php, port => Port}]
    end;
the_end(_League, _SeasonStillToReplay) ->
    [].

end_state(#{<<"funds">> := Funds, <<"teams">> := Teams, <<"house">> := House,
            <<"draft">> := Draft}) ->
    #{funds => Funds, house => House, draft => binary_to_atom(Draft),
      teams => lists:sort([{Team, Owner, Basis}
                           || #{<<"team">> := Team, <<"owner">> := Owner,
                                <<"basis">> := Basis} <- Teams])}.

port_end_state(#{owners := Owners, teams := Teams, draft := #{stage := Stage}} = State) ->
    #{funds => #{Owner => Funds || Owner := #{funds_units := Funds} <- Owners},
      house => league_state:house_balance(State),
      draft => draft_status(Stage),
      teams => lists:sort([{Team, Owner, Basis}
                           || Team := #{owner := Owner, basis_units := Basis} <- Teams])}.

draft_status(setup) -> setup;
draft_status({picking, _Slot}) -> active;
draft_status(complete) -> complete.

step(League, #{<<"event">> := <<"setup">>, <<"polls">> := Polls} = Step, Fixture) ->
    [ok = league:observe(League, poll(Poll, Fixture)) || Poll <- Polls],
    Before = ledgers(League),
    Funded = [league:act(League, #{at => at(Step), actor => commissioner(League),
                                   command => {confirm_contribution, Owner, Units}})
              || #{<<"owner">> := Owner, <<"amount">> := Units} <- ledger(Step)],
    compare(Step, lists:usort(Funded) =:= [ok], new_rows(Before, ledgers(League)));
step(League, #{<<"event">> := <<"action">>, <<"status">> := Status} = Step, _Fixture) ->
    Before = ledgers(League),
    Answer = league:act(League, #{at => at(Step), actor => maps:get(<<"owner">>, Step),
                                  command => command(Step)}),
    compare(Step#{<<"answer">> => Answer}, (Answer =:= ok) =:= (Status < 400),
            new_rows(Before, ledgers(League))).

compare(#{<<"ledger">> := Recorded} = Step, SameAnswer, {OwnerRows, HouseRows}) ->
    Expected = {[row(Row) || #{<<"book">> := <<"owner">>} = Row <- Recorded],
                [row(Row) || #{<<"book">> := <<"house">>} = Row <- Recorded]},
    case SameAnswer andalso Expected =:= {OwnerRows, HouseRows} of
        true -> [];
        false -> [#{step => maps:without([<<"ledger">>, <<"polls">>], Step),
                    php => Expected, port => {OwnerRows, HouseRows}}]
    end.

command(#{<<"action">> := <<"create_draft">>}) ->
    create_draft;
command(#{<<"action">> := <<"set_draft_order">>, <<"in">> := In}) ->
    {set_draft_order, maps:get(<<"owner_ids">>, In)};
command(#{<<"action">> := <<"start_draft">>}) ->
    start_draft;
command(#{<<"action">> := <<"draft_select">>, <<"in">> := #{<<"team_id">> := null}}) ->
    {draft_select, <<>>};
command(#{<<"action">> := <<"draft_select">>, <<"in">> := #{<<"team_id">> := Team}}) ->
    {draft_select, Team};
command(#{<<"action">> := <<"draft_pass">>}) ->
    draft_pass;
command(#{<<"action">> := <<"undo_pick">>}) ->
    undo_pick.

ledgers(League) ->
    State = league:state(League),
    {league_state:owner_ledger(State), league_state:house_ledger(State)}.

new_rows({OwnerBefore, HouseBefore}, {OwnerAfter, HouseAfter}) ->
    {lists:nthtail(length(OwnerBefore), OwnerAfter),
     lists:nthtail(length(HouseBefore), HouseAfter)}.

row(#{<<"entry">> := Entry, <<"owner">> := Owner, <<"type">> := Type,
      <<"amount">> := Amount, <<"balance_after">> := After, <<"related">> := Related}) ->
    #{entry => Entry, owner => none_if_null(Owner), type => binary_to_atom(Type),
      amount_units => Amount, balance_after_units => After, related => related(Related)}.

none_if_null(null) -> none;
none_if_null(Owner) -> Owner.

related(null) -> none;
related([Kind, Id]) -> {binary_to_atom(Kind), Id}.

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
           <<"buyback_narrows_on">> := NarrowsOn, <<"buyback_closes_on">> := ClosesOn}) ->
    #{max_teams => binary_to_integer(MaxTeams), stake_units => binary_to_integer(Stake),
      buyback_narrows_on => league_date(NarrowsOn),
      buyback_closes_on => league_date(ClosesOn)}.

league_date(<<Year:4/binary, "-", Month:2/binary, "-", Day:2/binary>>) ->
    {league_local, {binary_to_integer(Year), binary_to_integer(Month),
                    binary_to_integer(Day)}}.

schedule(#{<<"games">> := Weeks}) ->
    [#{week => binary_to_integer(Week), home_team => Home, away_team => Away,
       kickoff => {utc, Kickoff}}
     || Week := Games <- Weeks,
        #{<<"home">> := Home, <<"away">> := Away, <<"kickoff">> := Kickoff} <- Games].

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
