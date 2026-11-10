-module(football_season_settlement).

-rule("§13").

-export([decide/1]).

-export_type([season/0, blocker/0, decision/0]).

-type units() :: integer().

-type season() :: #{
    prize_pool := frozen | not_frozen,
    slots_outstanding := non_neg_integer(),
    house_units := units(),
    settled := boolean(),
    balances := [{Owner :: term(), units()}]
}.

-type blocker() ::
    prize_pool_not_frozen
  | {payouts_not_recorded, pos_integer()}
  | {house_still_holds_units, units()}.

-type decision() ::
    {settle, [{Owner :: term(), units()}]}
  | {refused, {not_ready, [blocker(), ...]}}
  | {refused, already_settled}.

-spec decide(season()) -> decision().
decide(#{settled := Settled, balances := Balances} = Season) ->
    case {blockers(Season), Settled} of
        {[], false} -> {settle, paid_out(Balances)};
        {[], true} -> {refused, already_settled};
        {Blockers, _Settled} -> {refused, {not_ready, Blockers}}
    end.

blockers(#{prize_pool := Pool, slots_outstanding := Outstanding, house_units := House}) ->
    [prize_pool_not_frozen || Pool =:= not_frozen]
        ++ [{payouts_not_recorded, Outstanding} || Outstanding > 0]
        ++ [{house_still_holds_units, House} || House =/= 0, Outstanding =:= 0].

paid_out(Balances) ->
    lists:sort(fun holds_more/2, [Balance || {_Owner, Units} = Balance <- Balances,
                                             Units =/= 0]).

holds_more({_Owner, Units}, {_Other, OtherUnits}) -> Units >= OtherUnits.
