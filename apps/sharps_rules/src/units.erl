-module(units).

-export([fraction_of/3]).

-spec fraction_of(non_neg_integer(), non_neg_integer(), pos_integer()) ->
    non_neg_integer().
fraction_of(Units, Numerator, Denominator) ->
    (2 * Units * Numerator + Denominator) div (2 * Denominator).
