-module(football_battle_settlement).

-rule("§11").

-export([decide/2]).

-export_type([accepted_battle/0, instruction/0, settlement/0, refusal/0]).

-type units() :: non_neg_integer().

-type owner_id() :: pos_integer().

-type basis_points() :: 0..10000.

-type accepted_battle() :: #{
    owner_a := owner_id(),
    owner_b := owner_id(),
    stake_units := units(),
    house_fee_basis_points := basis_points()
}.

-type instruction() :: refund_both_stakes | {pay_winner, owner_id()}.

-type settlement() ::
    {refund, #{stake_units := units()}}
  | {settle, #{
        winner := owner_id(),
        stake_units := units(),
        pot_units := units(),
        house_fee_units := units(),
        payout_units := units()
    }}.

-type refusal() :: {refused, no_accepted_battle | winner_not_in_battle}.

-spec decide(accepted_battle() | no_accepted_battle, instruction()) ->
    settlement() | refusal().
decide(no_accepted_battle, _Instruction) ->
    {refused, no_accepted_battle};
decide(#{stake_units := Stake}, refund_both_stakes) ->
    {refund, #{stake_units => Stake}};
decide(#{owner_a := Winner} = Battle, {pay_winner, Winner}) ->
    pay(Winner, Battle);
decide(#{owner_b := Winner} = Battle, {pay_winner, Winner}) ->
    pay(Winner, Battle);
decide(#{}, {pay_winner, _OwnerOutsideTheBattle}) ->
    {refused, winner_not_in_battle}.

pay(Winner, #{stake_units := Stake, house_fee_basis_points := HouseFeeBasisPoints}) ->
    Pot = 2 * Stake,
    HouseFee = units:fraction_of(Pot, HouseFeeBasisPoints, 10000),
    {settle, #{
        winner => Winner,
        stake_units => Stake,
        pot_units => Pot,
        house_fee_units => HouseFee,
        payout_units => Pot - HouseFee
    }}.
