-module(adjustment).

-rule("§13").

-export([decide/1]).

-type units() :: integer().

-spec decide(#{amount_units := units(), reason := binary(), in_the_league := boolean(),
               season_settled := boolean()}) ->
    {adjust, units(), Reason :: binary()}
  | {refused, zero_amount | reason_required | not_in_the_league | season_settled}.
decide(#{amount_units := 0}) ->
    {refused, zero_amount};
decide(#{reason := Reason} = Adjustment) ->
    stated(string:trim(Reason), Adjustment).

stated(<<>>, _Adjustment) ->
    {refused, reason_required};
stated(_Reason, #{in_the_league := false}) ->
    {refused, not_in_the_league};
stated(_Reason, #{season_settled := true}) ->
    {refused, season_settled};
stated(Reason, #{amount_units := Amount}) ->
    {adjust, Amount, Reason}.
