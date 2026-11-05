-module(football_playoff_payout).

-rule("§12").
-ruled_by(spencer).

-export([decide/1, estimates/2]).

-export_type([basis_points/0, slot/0, decision/0]).

-type units() :: non_neg_integer().

-type basis_points() :: pos_integer().

-type slot() :: #{
    remaining_pool_units := units(),
    round_basis_points := basis_points(),
    unrecorded_basis_points := basis_points(),
    winner := owned | house_owned
}.

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
