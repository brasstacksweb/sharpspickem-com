-module(league_trades).

-export([propose/3, confirm/3, cancel/3, settle/3]).

-type owner() :: binary().

-type team() :: binary().

-type utc() :: {utc, integer()}.

-type proposal() :: #{to := owner(), sending := team() | no_team,
                      receiving := team() | no_team, cash_units := non_neg_integer(),
                      paid_by := them | me}.

-spec propose(owner(), proposal(), #{now := utc(), state := league_state:state()}) ->
    [league_state:event()] | {refused, term()}.
propose(Owner, #{to := Partner, sending := Sending, receiving := Receiving,
                 cash_units := Cash, paid_by := PaidBy}, #{now := Now, state := State}) ->
    maybe
        ok ?= season_running(Now, State),
        ok ?= a_partner(Owner, Partner, State),
        ok ?= moves_a_team(Sending, Receiving),
        ok ?= held(Sending, Owner, State),
        ok ?= held(Receiving, Partner, State),
        ok ?= cash_for_a_team(Cash, PaidBy, Sending, Receiving),
        ok ?= within_the_maximum(Owner, Partner, Sending, Receiving, State),
        ok ?= not_promised(Sending, State),
        ok ?= not_promised(Receiving, State),
        #{trades_proposed := Proposed} = State,
        [{trade_proposed, #{number => Proposed + 1, owner_a => Owner, owner_b => Partner,
                            team_from_a => Sending, team_from_b => Receiving,
                            cash_to_a_units => signed(Cash, PaidBy), confirmed => false}}]
    end.

season_running(Now, State) ->
    case league_state:season_over(Now, State) of
        true -> {refused, season_over};
        false -> ok
    end.

a_partner(Owner, Owner, _State) -> {refused, not_with_yourself};
a_partner(_Owner, Partner, #{owners := Owners}) when is_map_key(Partner, Owners) -> ok;
a_partner(_Owner, _Stranger, _State) -> {refused, not_in_this_league}.

moves_a_team(no_team, no_team) -> {refused, moves_no_team};
moves_a_team(_Sending, _Receiving) -> ok.

held(no_team, _Owner, _State) ->
    ok;
held(Team, Owner, State) ->
    case league_state:team(Team, State) of
        #{owner := Owner} -> ok;
        _NotTheirs -> {refused, not_their_team}
    end.

cash_for_a_team(Cash, them, no_team, _Receiving) when Cash > 0 ->
    {refused, paid_with_no_team_behind_it};
cash_for_a_team(Cash, me, _Sending, no_team) when Cash > 0 ->
    {refused, paid_with_no_team_behind_it};
cash_for_a_team(_Cash, _PaidBy, _Sending, _Receiving) ->
    ok.

within_the_maximum(Owner, Partner, Sending, Receiving, State) ->
    MaxTeams = league_state:max_teams(State),
    After = fun(Who, Gets, Sends) ->
                    length(league_state:held_by(Who, State)) + count(Gets) - count(Sends)
            end,
    case After(Owner, Receiving, Sending) > MaxTeams
        orelse After(Partner, Sending, Receiving) > MaxTeams of
        true -> {refused, over_the_maximum};
        false -> ok
    end.

count(no_team) -> 0;
count(_Team) -> 1.

not_promised(no_team, _State) ->
    ok;
not_promised(Team, State) ->
    case lists:any(fun(#{team_from_a := FromA, team_from_b := FromB}) ->
                           Team =:= FromA orelse Team =:= FromB
                   end, league_state:pending_trades(State)) of
        true -> {refused, already_promised};
        false -> ok
    end.

signed(Cash, them) -> Cash;
signed(Cash, me) -> -Cash.

-spec confirm(owner(), pos_integer(), #{now := utc(), state := league_state:state()}) ->
    [league_state:event()] | {refused, term()}.
confirm(Owner, Number, #{now := Now, state := State}) ->
    maybe
        {ok, #{owner_b := Partner} = Trade} ?= pending(Number, State),
        ok ?= the_partner(Owner, Partner),
        ok ?= season_running(Now, State),
        Confirmed = {trade_confirmed, Number},
        [Confirmed | settle(Trade#{confirmed := true}, Now,
                            league_state:apply_event(Confirmed, State))]
    end.

pending(Number, State) ->
    case [Trade || #{number := Pending} = Trade <- league_state:pending_trades(State),
                   Pending =:= Number] of
        [Trade] -> {ok, Trade};
        [] -> {refused, no_such_trade}
    end.

the_partner(Partner, Partner) -> ok;
the_partner(_Someone, _Partner) -> {refused, only_the_partner_confirms}.

-spec cancel(owner(), pos_integer(), league_state:state()) ->
    [league_state:event()] | {refused, term()}.
cancel(Owner, Number, #{commissioner := Commissioner} = State) ->
    case pending(Number, State) of
        {ok, #{owner_a := A, owner_b := B}} when Owner =:= A; Owner =:= B;
                                                 Owner =:= Commissioner ->
            [{trade_cancelled, Number}];
        {ok, _NotTheirs} ->
            {refused, not_your_trade};
        Refused ->
            Refused
    end.

-spec settle(league_state:trade(), utc(), league_state:state()) -> [league_state:event()].
settle(#{number := Number, owner_a := A, owner_b := B, team_from_a := FromA,
         team_from_b := FromB} = Trade, Now, State) ->
    Availability = league_state:availability(Now, State),
    Teams = #{Team => team(Team, Availability, Now, State)
              || Team <- [FromA, FromB], Team =/= no_team},
    League = #{teams => Teams,
               owners => #{Owner => league_market:holding(Owner, Now, State)
                           || Owner <- [A, B]},
               max_teams => league_state:max_teams(State),
               stake_units => league_state:stake(State),
               battle_season => league_state:battle_season(Now, State)},
    case football_trade:decide(maps:with([owner_a, owner_b, team_from_a, team_from_b,
                                          cash_to_a_units, confirmed], Trade), League) of
        {settle, #{moves := Moves}} -> [{trade_settled, Number, Moves}];
        _HeldOrRefused -> []
    end.

team(Team, Availability, Now, State) ->
    #{owner := Owner} = Held = league_state:team(Team, State),
    #{Team := #{tradable := Tradable}} = Availability,
    #{owner => Owner, tradable => Tradable =:= yes,
      basis_units => maps:get(basis_units, Held, 0),
      extra_games_this_week => league_state:team_extra_games(Team, Now, State)}.
