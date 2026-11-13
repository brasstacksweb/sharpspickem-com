-module(football_playoff_payout).

-rule("§12").
-ruled_by(spencer).

-export([decide/1, estimates/2, schedule/0, share/1, refund/2]).

-export_type([basis_points/0, slot/0, decision/0, round/0, recorded/0]).

-type units() :: non_neg_integer().

-type basis_points() :: pos_integer().

-type round() :: bye | football_playoff:round().

-type winner() :: owned | house_owned.

-type slot() :: #{
    remaining_pool_units := units(),
    round_basis_points := basis_points(),
    unrecorded_basis_points := basis_points(),
    winner := winner()
}.

-type recorded() :: #{round := round(), paid_units := units(), term() => term()}.

-type decision() ::
    {pay_units, units()}
  | {forfeited, rolls_into_later_rounds}
  | {forfeited, {refund_to_owners_units, units()}}.

-spec decide(slot()) -> decision().
decide(#{winner := owned, remaining_pool_units := Remaining,
         round_basis_points := RoundShare, unrecorded_basis_points := Unrecorded})
  when RoundShare =< Unrecorded ->
    {pay_units, units:fraction_of(Remaining, RoundShare, Unrecorded)};
decide(#{winner := house_owned, remaining_pool_units := Remaining,
         round_basis_points := LastShare, unrecorded_basis_points := LastShare}) ->
    {forfeited, {refund_to_owners_units, Remaining}};
decide(#{winner := house_owned, round_basis_points := RoundShare,
         unrecorded_basis_points := Unrecorded})
  when RoundShare < Unrecorded ->
    {forfeited, rolls_into_later_rounds}.

-spec estimates(units(), [{Round, basis_points()}]) -> [{Round, units()}].
estimates(PoolUnits, Rounds) ->
    [{Round, units:fraction_of(PoolUnits, RoundShare, 10000)}
     || {Round, RoundShare} <- Rounds].

-spec schedule() -> [{round(), basis_points(), Games :: pos_integer()}].
schedule() ->
    [{bye, 300, 4},
     {first_round, 300, 4},
     {quarterfinal, 600, 4},
     {semifinal, 1100, 2},
     {championship, 3000, 1}].

-spec share(#{pool_units := units(), recorded := [recorded()], round := round(),
              winner := winner()}) -> decision().
share(#{pool_units := Pool, recorded := Recorded, round := Round, winner := Winner}) ->
    {Earlier, [{Round, RoundShare, _Games} | _Later] = FromThisRound} =
        lists:splitwith(fun(Scheduled) -> not is_round(Round, Scheduled) end, schedule()),
    decide(#{remaining_pool_units => Pool - paid_in(Earlier, Recorded)
                                          - still_owed(Pool, Earlier, Recorded),
             round_basis_points => RoundShare,
             unrecorded_basis_points => scheduled_basis_points(FromThisRound),
             winner => Winner}).

is_round(Round, {Scheduled, _Share, _Games}) -> Round =:= Scheduled.

paid_in(Rounds, Recorded) ->
    lists:sum([Paid || #{round := Round, paid_units := Paid} <- Recorded,
                       lists:keymember(Round, 1, Rounds)]).

still_owed(Pool, Rounds, Recorded) ->
    lists:sum([units:fraction_of(Pool, max(0, Games - recorded_in(Round, Recorded)) * Share,
                                 10000)
               || {Round, Share, Games} <- Rounds]).

recorded_in(Round, Recorded) ->
    length([Slot || #{round := SlotRound} = Slot <- Recorded, SlotRound =:= Round]).

scheduled_basis_points(Rounds) ->
    lists:sum([Games * Share || {_Round, Share, Games} <- Rounds]).

-spec refund(units(), [{Owner, Contributed :: integer()}]) -> [{Owner, units()}].
refund(Remainder, Contributions) ->
    case lists:sort(fun contributed_more/2,
                    [Contributor || {_Owner, Paid} = Contributor <- Contributions,
                                    Paid > 0]) of
        [] -> [];
        Contributors -> with_the_dust_to_the_first(Remainder, Contributors)
    end.

contributed_more({_Owner, Paid}, {_Other, OtherPaid}) -> Paid >= OtherPaid.

with_the_dust_to_the_first(Remainder, [{First, _Paid} | _Others] = Contributors) ->
    Total = lists:sum([Paid || {_Owner, Paid} <- Contributors]),
    [{First, FirstShare} | OtherShares] =
        [{Owner, Remainder * Paid div Total} || {Owner, Paid} <- Contributors],
    Dust = Remainder - FirstShare - lists:sum([Share || {_Owner, Share} <- OtherShares]),
    [{Owner, Share} || {Owner, Share} <- [{First, FirstShare + Dust} | OtherShares],
                       Share > 0].
