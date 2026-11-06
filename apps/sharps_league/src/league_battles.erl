-module(league_battles).

-export([created/2, bound/2, settled/2, raise/4, answer/4]).

-type owner() :: binary().

-type utc() :: {utc, integer()}.

-spec created(utc(), league_state:state()) -> [league_state:event()].
created(Now, #{battles_created := Created} = State) ->
    Matchups = football_battle:matchups(upcoming(State), owners(State),
                                        #{now => Now, already => already(State)}),
    [{battle_created, battle(Number, Matchup, State)}
     || {Number, Matchup} <- lists:zip(lists:seq(Created + 1, Created + length(Matchups)),
                                       Matchups)].

upcoming(State) ->
    Regular = [Game || #{season_type := regular} = Game <- league_state:games(State)],
    lists:sort(fun(#{kickoff := One}, #{kickoff := Other}) -> One =< Other end, Regular).

owners(#{teams := Teams}) ->
    #{Team => Owner || Team := #{owner := Owner} <- Teams, Owner =/= house}.

already(State) ->
    [{Week, Home, Away} || #{week := Week, home_team := Home, away_team := Away}
                               <- league_state:battles(State)].

battle(Number, Matchup, #{settings := #{house_fee_basis_points := HouseFee}} = State) ->
    Matchup#{number => Number, stake_units => league_state:stake(State),
             house_fee_basis_points => HouseFee, status => pending, raise => none}.

-spec bound(utc(), league_state:state()) -> [league_state:event()].
bound(Now, State) ->
    lists:append([binding(Battle, Now, State)
                   || #{status := pending} = Battle <- league_state:battles(State)]).

binding(#{number := Number, home_team := Home, away_team := Away} = Battle, Now, State) ->
    #{home_owner := HomeOwner, away_owner := AwayOwner, stake_units := Stake} = Battle,
    Binding = #{home_owner => HomeOwner, away_owner => AwayOwner,
                holders_now => {holder(Home, State), holder(Away, State)},
                kickoff => kickoff(Battle, State), now => Now, stake_units => Stake,
                funds_units => {league_state:funds(HomeOwner, State),
                                league_state:funds(AwayOwner, State)}},
    case football_battle:bind(Binding, lines_frozen) of
        not_yet -> [];
        dissolved -> [{battle_dissolved, Number}];
        {rejected, _Why} -> [{battle_rejected, Number}];
        bound -> [{battle_bound, Number}]
    end.

holder(Team, State) ->
    maps:get(owner, league_state:team(Team, State)).

kickoff(Battle, State) ->
    case league_state:game_of(Battle, State) of
        #{kickoff := Kickoff} -> Kickoff;
        not_scheduled -> unscheduled
    end.

-spec settled(utc(), league_state:state()) -> [league_state:event()].
settled(Now, State) ->
    lists:append([settlement(Battle, Game)
                  || #{status := accepted} = Battle <- league_state:battles(State),
                     {final, Game} <- [league_state:final_score(Battle, Now, State)]]).

settlement(#{number := Number, home_owner := Home, away_owner := Away,
             stake_units := Stake, house_fee_basis_points := HouseFee},
           #{line := Line} = Game) ->
    Accepted = #{owner_a => Home, owner_b => Away, stake_units => Stake,
                 house_fee_basis_points => HouseFee},
    Instruction = instruction(Line, Game, Home, Away),
    case football_battle_settlement:decide(Accepted, Instruction) of
        {refund, _Stake} ->
            [{battle_refunded, Number}];
        {settle, #{winner := Winner, payout_units := Payout, house_fee_units := Fee}} ->
            [{battle_settled, Number, #{winner => Winner, payout_units => Payout,
                                        house_fee_units => Fee}}]
    end.

instruction(Line, Game, Home, Away) ->
    case football_battle_result:decide(Line, Game) of
        {push, _How} -> refund_both_stakes;
        {home, _By} -> {pay_winner, Home};
        {away, _By} -> {pay_winner, Away}
    end.

-spec raise(owner(), pos_integer(), pos_integer(), #{now := utc(),
                                                       state := league_state:state()}) ->
    [league_state:event()] | {refused, term()}.
raise(Owner, Number, Stake, #{now := Now, state := State}) ->
    case live(Number, State) of
        {ok, #{stake_units := Current} = Battle} ->
            Raise = #{battle => Battle, stake_units => Stake,
                      margin_call => league_market:standing(Owner, Now, State),
                      kicked_off => kicked_off(Battle, Now, State),
                      headroom => headroom(Owner, Stake - Current, Now, State)},
            case football_battle:raise(Owner, Raise) of
                {offered, Offered} -> [{stake_raise_offered, Number, Owner, Offered}];
                Refused -> Refused
            end;
        Refused ->
            Refused
    end.

live(Number, State) ->
    case [Battle || #{number := Live, status := Status} = Battle
                        <- league_state:battles(State),
                    Live =:= Number, Status =:= pending orelse Status =:= accepted] of
        [Battle] -> {ok, Battle};
        [] -> {refused, no_such_battle}
    end.

-spec answer(owner(), pos_integer(), accept | decline,
             #{now := utc(), state := league_state:state()}) ->
    [league_state:event()] | {refused, term()}.
answer(Owner, Number, Answer, #{now := Now, state := State}) ->
    case [Battle || #{number := Waiting} = Battle <- league_state:battles(State),
                    Waiting =:= Number] of
        [#{home_owner := Home, away_owner := Away, stake_units := Current,
           raise := Raise} = Battle] ->
            Debit = raise_debit(Raise, Current),
            Situation = #{battle => Battle,
                          kicked_off => kicked_off(Battle, Now, State),
                          funds_units => {league_state:funds(Home, State),
                                          league_state:funds(Away, State)},
                          headroom => {headroom(Home, Debit, Now, State),
                                       headroom(Away, Debit, Now, State)}},
            answered(Number, football_battle:answer_raise(Owner, Answer, Situation));
        [] ->
            {refused, no_raise_waiting}
    end.

raise_debit({offered, _By, Stake}, Current) -> Stake - Current;
raise_debit(none, _Current) -> 0.

answered(Number, declined) -> [{stake_raise_declined, Number}];
answered(Number, {raised, Stake, Debit}) -> [{stake_raised, Number, Stake, Debit}];
answered(_Number, Refused) -> Refused.

kicked_off(Battle, Now, State) ->
    case kickoff(Battle, State) of
        unscheduled -> true;
        Kickoff -> Kickoff =< Now
    end.

headroom(Owner, CashOut, Now, State) ->
    football_battle_reserve:headroom(
        (league_market:holding(Owner, Now, State))#{
            cash_out_units => CashOut, teams_gained => 0,
            max_teams => league_state:max_teams(State),
            stake_units => league_state:stake(State),
            battle_season => league_state:battle_season(Now, State)}).
