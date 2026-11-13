-module(football_battle).

-rule("§11").

-export([matchups/3, bind/2, raise/2, answer_raise/3]).

-export_type([game/0, matchup/0, binding/0]).

-define(LINE_FREEZE_SECONDS, 1800).

-type owner() :: binary().

-type team() :: binary().

-type utc() :: {utc, integer()}.

-type units() :: integer().

-type game() :: #{week := pos_integer(), home_team := team(), away_team := team(),
                  kickoff := utc(), line := football_battle_result:line(),
                  atom() => term()}.

-type matchup() :: #{week := pos_integer(), home_team := team(), away_team := team(),
                     home_owner := owner(), away_owner := owner(),
                     line := football_battle_result:line()}.

-type binding() :: #{
    home_owner := owner(),
    away_owner := owner(),
    holders_now := {owner() | house, owner() | house},
    kickoff := utc() | unscheduled,
    now := utc(),
    stake_units := units(),
    funds_units := {units(), units()}
}.

-type already() :: [{pos_integer(), team(), team()}].

-spec matchups([game()], #{team() => owner()}, #{now := utc(), already := already()}) ->
    [matchup()].
matchups(Games, Owners, #{now := Now, already := Already}) ->
    Upcoming = [Game || #{kickoff := Kickoff} = Game <- Games, Kickoff > Now],
    [matchup(Game, Owners) || Game <- this_week(Upcoming),
                              between_two_owners(Game, Owners),
                              not already_made(Game, Already)].

this_week([]) ->
    [];
this_week(Upcoming) ->
    Week = lists:min([Week || #{week := Week} <- Upcoming]),
    [Game || #{week := GameWeek} = Game <- Upcoming, GameWeek =:= Week].

between_two_owners(#{home_team := Home, away_team := Away}, Owners) ->
    case {maps:get(Home, Owners, house), maps:get(Away, Owners, house)} of
        {house, _Away} -> false;
        {_Home, house} -> false;
        {Same, Same} -> false;
        {_HomeOwner, _AwayOwner} -> true
    end.

already_made(#{week := Week, home_team := Home, away_team := Away}, Already) ->
    lists:member({Week, Home, Away}, Already)
        orelse lists:member({Week, Away, Home}, Already).

matchup(#{week := Week, home_team := Home, away_team := Away, line := Line}, Owners) ->
    #{week => Week, home_team => Home, away_team => Away,
      home_owner => maps:get(Home, Owners), away_owner => maps:get(Away, Owners),
      line => Line}.

-spec bind(binding(), lines_frozen | owners_changed) ->
    not_yet | dissolved | {rejected, could_not_cover_the_stake} | bound.
bind(#{home_owner := Home, away_owner := Away, holders_now := {Home, Away}} = Binding,
     _Why) ->
    when_the_line_freezes(Binding);
bind(_TeamChangedHands, _Why) ->
    dissolved.

when_the_line_freezes(#{kickoff := {utc, Kickoff}, now := {utc, Now}} = Binding)
  when Kickoff - ?LINE_FREEZE_SECONDS =< Now ->
    both_can_cover(Binding);
when_the_line_freezes(_StillOpen) ->
    not_yet.

both_can_cover(#{stake_units := Stake, funds_units := {Home, Away}})
  when Home >= Stake, Away >= Stake ->
    bound;
both_can_cover(_OneShort) ->
    {rejected, could_not_cover_the_stake}.

-spec raise(owner(), #{
    battle := #{home_owner := owner(), away_owner := owner(), stake_units := units(),
                raise := none | {offered, owner(), units()}, atom() => term()},
    stake_units := units(),
    margin_call := in_good_standing | in_margin_call,
    kicked_off := boolean(),
    headroom := football_battle_reserve:headroom()
}) -> {offered, units()} | {refused, atom()}.
raise(Owner, #{battle := Battle} = Raise) ->
    maybe
        ok ?= one_of_the_two(Owner, Battle),
        ok ?= not_in_margin_call(Raise),
        ok ?= more_than_the_stake(Raise),
        ok ?= before_kickoff(Raise),
        ok ?= within_the_reserve(Raise),
        ok ?= no_raise_waiting(Battle),
        {offered, maps:get(stake_units, Raise)}
    end.

one_of_the_two(Owner, #{home_owner := Owner}) -> ok;
one_of_the_two(Owner, #{away_owner := Owner}) -> ok;
one_of_the_two(_Outsider, _Battle) -> {refused, not_in_this_battle}.

not_in_margin_call(#{margin_call := in_good_standing}) -> ok;
not_in_margin_call(#{margin_call := in_margin_call}) -> {refused, in_margin_call}.

more_than_the_stake(#{stake_units := New, battle := #{stake_units := Current}})
  when New > Current ->
    ok;
more_than_the_stake(_NotARaise) ->
    {refused, not_more_than_the_stake}.

before_kickoff(#{kicked_off := false}) -> ok;
before_kickoff(#{kicked_off := true}) -> {refused, kicked_off}.

within_the_reserve(#{headroom := {fits, _Figures}}) -> ok;
within_the_reserve(#{headroom := Short}) ->
    {refused, {would_spend_into_the_reserve, Short}}.

no_raise_waiting(#{raise := none}) -> ok;
no_raise_waiting(#{raise := {offered, _By, _Stake}}) -> {refused, a_raise_is_waiting}.

-spec answer_raise(owner(), accept | decline, #{
    battle := #{home_owner := owner(), away_owner := owner(), stake_units := units(),
                raise := none | {offered, owner(), units()},
                status := pending | accepted | settled | refunded | rejected,
                atom() => term()},
    kicked_off := boolean(),
    funds_units := {units(), units()},
    headroom := {football_battle_reserve:headroom(), football_battle_reserve:headroom()}
}) -> declined | {raised, units(), Debit :: units()} | {refused, atom()}.
answer_raise(_Owner, _Answer, #{battle := #{raise := none}}) ->
    {refused, no_raise_waiting};
answer_raise(Owner, Answer, #{battle := Battle} = Situation) ->
    #{raise := {offered, By, Stake}} = Battle,
    maybe
        ok ?= the_other_owner(Owner, By, Battle),
        accepted_or_declined(Answer, Stake, Situation)
    end.

the_other_owner(By, By, _Battle) -> {refused, only_the_other_owner};
the_other_owner(Owner, _By, Battle) -> one_of_the_two(Owner, Battle).

accepted_or_declined(decline, _Stake, _Answer) ->
    declined;
accepted_or_declined(accept, _Stake, #{kicked_off := true}) ->
    {refused, kicked_off};
accepted_or_declined(accept, Stake, #{battle := #{status := pending}}) ->
    {raised, Stake, 0};
accepted_or_declined(accept, Stake, #{battle := #{status := accepted,
                                                  stake_units := Current},
                                      funds_units := {Home, Away}})
  when Home < Stake - Current; Away < Stake - Current ->
    {refused, both_owners_cannot_cover_the_raise};
accepted_or_declined(accept, Stake, #{battle := #{stake_units := Current},
                                      headroom := {{fits, _}, {fits, _}}}) ->
    {raised, Stake, Stake - Current};
accepted_or_declined(accept, _Stake, _OneShortOfTheReserve) ->
    {refused, would_spend_into_the_reserve}.
