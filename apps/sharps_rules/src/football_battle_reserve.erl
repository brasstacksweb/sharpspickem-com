-module(football_battle_reserve).

-rule("§11").
-ruled_by(spencer).

-export([required_units/1, headroom/1, margin_call/1]).

-export_type([battle_season/0, holding/0, cash_on_hand/0, spending/0,
              headroom/0, standing/0]).

-type units() :: integer().

-type battle_season() :: battles_being_created | battles_over.

-type holding() :: #{
    teams_held := non_neg_integer(),
    extra_games_this_week := non_neg_integer(),
    stake_units := units(),
    battle_season := battle_season(),
    atom() => term()
}.

-type cash_on_hand() :: #{
    funds_units := units(),
    escrow_units := units(),
    teams_held := non_neg_integer(),
    extra_games_this_week := non_neg_integer(),
    stake_units := units(),
    battle_season := battle_season()
}.

-type spending() :: #{
    funds_units := units(),
    cash_out_units := units(),
    escrow_units := units(),
    teams_held := non_neg_integer(),
    teams_gained := non_neg_integer(),
    max_teams := non_neg_integer(),
    extra_games_this_week := non_neg_integer(),
    stake_units := units(),
    battle_season := battle_season()
}.

-type headroom() :: {fits | spends_into_the_reserve, #{
    teams_after := non_neg_integer(),
    reserve_units := units(),
    escrow_credit_units := units(),
    held_back_units := units(),
    headroom_units := units()
}}.

-type standing() ::
    {in_good_standing, #{required_units := units()}}
  | {in_margin_call, #{required_units := units(), short_units := units()}}.

-spec required_units(holding()) -> units().
required_units(#{battle_season := battles_over}) ->
    0;
required_units(#{battle_season := battles_being_created, teams_held := Teams,
                 extra_games_this_week := ExtraGames, stake_units := Stake})
  when is_integer(Teams), is_integer(ExtraGames), is_integer(Stake) ->
    (Teams + ExtraGames) * Stake.

-spec headroom(spending()) -> headroom().
headroom(#{funds_units := Funds, cash_out_units := CashOut, escrow_units := Escrow,
           teams_held := TeamsHeld, teams_gained := TeamsGained,
           max_teams := MaxTeams} = Spending) ->
    TeamsAfter = min(MaxTeams, TeamsHeld + TeamsGained),
    Reserve = required_units(Spending#{teams_held := TeamsAfter}),
    EscrowCredit = min(Escrow, Reserve),
    HeldBack = Reserve - EscrowCredit,
    Headroom = Funds - CashOut - HeldBack,
    {fits_or_not(Headroom), #{teams_after => TeamsAfter,
                              reserve_units => Reserve,
                              escrow_credit_units => EscrowCredit,
                              held_back_units => HeldBack,
                              headroom_units => Headroom}}.

fits_or_not(Headroom) when Headroom >= 0 -> fits;
fits_or_not(_Headroom) -> spends_into_the_reserve.

-spec margin_call(cash_on_hand()) -> standing().
margin_call(#{funds_units := Funds, escrow_units := Escrow} = CashOnHand) ->
    standing(required_units(CashOnHand), Funds + Escrow).

standing(Required, Covered) when Covered >= Required ->
    {in_good_standing, #{required_units => Required}};
standing(Required, Covered) ->
    {in_margin_call, #{required_units => Required, short_units => Required - Covered}}.
