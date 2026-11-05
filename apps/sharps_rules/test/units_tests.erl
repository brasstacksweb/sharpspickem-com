-module(units_tests).

-include_lib("eunit/include/eunit.hrl").

fraction_of_rounds_half_up_test_() ->
    [
        {"a whole result is exact",
         ?_assertEqual(100, units:fraction_of(1000, 1000, 10000))},
        {"exactly half a unit rounds up; catches truncating",
         ?_assertEqual(26, units:fraction_of(1020, 250, 10000))},
        {"just under half a unit rounds down; catches always rounding up",
         ?_assertEqual(25, units:fraction_of(1018, 250, 10000))},
        {"just over half a unit rounds up",
         ?_assertEqual(67, units:fraction_of(666, 1000, 10000))},
        {"the whole of an amount is the amount",
         ?_assertEqual(60001, units:fraction_of(60001, 3000, 3000))},
        {"a third of 100 is 33, and two thirds is 67",
         ?_assertEqual({33, 67},
                       {units:fraction_of(100, 1, 3), units:fraction_of(100, 2, 3)})}
    ].
