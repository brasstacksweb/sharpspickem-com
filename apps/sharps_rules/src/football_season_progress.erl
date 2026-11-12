-module(football_season_progress).

-export([progress/1]).

-export_type([mark/0, fraction/0]).

-define(SHORT_OF_THE_NEXT_MARK, {23, 25}).

-type league_date() :: {league_local, calendar:date()}.

-type milestone() :: draft | cfp_pricing | closes | battles_end.

-type mark() :: #{milestone := milestone(), reached := boolean(),
                  on := league_date() | not_dated}.

-type fraction() :: {Numerator :: non_neg_integer(), Denominator :: pos_integer()}.

-type season() :: #{marks := [mark()], today := league_date(),
                    week := pos_integer() | unknown, committee_first_week := pos_integer()}.

-spec progress(season()) -> fraction().
progress(#{marks := Marks} = Season) ->
    along(length([Mark || #{reached := true} = Mark <- Marks]), Marks, Season).

along(0, _Marks, _Season) ->
    {0, 1};
along(Reached, Marks, _Season) when Reached >= length(Marks) ->
    {1, 1};
along(Reached, Marks, Season) ->
    Segments = length(Marks) - 1,
    {Into, Span} = capped(into_the_segment(lists:nth(Reached, Marks),
                                           lists:nth(Reached + 1, Marks), Season)),
    lowest_terms((Reached - 1) * Span + Into, Segments * Span).

into_the_segment(#{on := {league_local, From}}, #{on := {league_local, To}},
                 #{today := {league_local, Today}}) when To > From ->
    {days(Today) - days(From), days(To) - days(From)};
into_the_segment(_Last, #{milestone := cfp_pricing},
                 #{week := Week, committee_first_week := FirstWeek})
  when is_integer(Week), FirstWeek > 1 ->
    {Week - 1, FirstWeek - 1};
into_the_segment(_Last, _Next, _Season) ->
    {0, 1}.

capped({Into, _Span}) when Into < 0 ->
    {0, 1};
capped({Into, Span}) ->
    {CapNumerator, CapDenominator} = ?SHORT_OF_THE_NEXT_MARK,
    case Into * CapDenominator > Span * CapNumerator of
        true -> ?SHORT_OF_THE_NEXT_MARK;
        false -> {Into, Span}
    end.

days(Date) ->
    calendar:date_to_gregorian_days(Date).

lowest_terms(Numerator, Denominator) ->
    Divisor = greatest_common_divisor(Numerator, Denominator),
    {Numerator div Divisor, Denominator div Divisor}.

greatest_common_divisor(Larger, 0) -> Larger;
greatest_common_divisor(Larger, Smaller) ->
    greatest_common_divisor(Smaller, Larger rem Smaller).
