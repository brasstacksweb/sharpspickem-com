-module(football_battle_result).

-rule("§11").
-ruled_by(spencer).

-export([decide/2]).

-export_type([line/0, final_score/0, outcome/0]).

-type tenths_of_a_point() :: integer().

-type line() :: {home_spread_tenths, tenths_of_a_point()} | no_line_quoted.

-type final_score() :: #{
    home_points := non_neg_integer(),
    away_points := non_neg_integer(),
    atom() => term()
}.

-type side() :: home | away.

-type outcome() ::
    {side(), {covered_by_tenths, pos_integer()}}
  | {side(), {won_straight_up_by_points, pos_integer()}}
  | {push, landed_on_the_line}
  | {push, tied_with_no_line_quoted}.

-spec decide(line(), final_score()) -> outcome().
decide(Line, #{home_points := HomePoints, away_points := AwayPoints}) ->
    settle_on(Line, HomePoints - AwayPoints).

settle_on({home_spread_tenths, HomeSpread}, HomeLead) ->
    against_the_line(10 * HomeLead + HomeSpread);
settle_on(no_line_quoted, HomeLead) ->
    straight_up(HomeLead).

against_the_line(HomeCoverTenths) when HomeCoverTenths > 0 ->
    {home, {covered_by_tenths, HomeCoverTenths}};
against_the_line(HomeCoverTenths) when HomeCoverTenths < 0 ->
    {away, {covered_by_tenths, -HomeCoverTenths}};
against_the_line(0) ->
    {push, landed_on_the_line}.

straight_up(HomeLead) when HomeLead > 0 ->
    {home, {won_straight_up_by_points, HomeLead}};
straight_up(HomeLead) when HomeLead < 0 ->
    {away, {won_straight_up_by_points, -HomeLead}};
straight_up(0) ->
    {push, tied_with_no_line_quoted}.
