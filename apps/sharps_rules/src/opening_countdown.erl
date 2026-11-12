-module(opening_countdown).

-rule("§6").

-export([countdown/2]).

-export_type([countdown/0, shown_as/0]).

-define(MINUTE, 60).
-define(HOUR, 3600).
-define(DAY, 86400).

-type utc() :: {utc, integer()}.

-type shown_as() ::
    settling_now
  | under_a_minute
  | {minutes, non_neg_integer()}
  | {hours, non_neg_integer(), Minutes :: non_neg_integer()}
  | {days, non_neg_integer(), Hours :: non_neg_integer()}.

-type countdown() :: #{at := utc(), seconds_left := non_neg_integer(), due := boolean(),
                       shown_as := shown_as()}.

-spec countdown(Opening :: utc() | no_opening, Now :: utc()) ->
    countdown() | nothing_to_count_to.
countdown(no_opening, {utc, _Now}) ->
    nothing_to_count_to;
countdown({utc, At} = Opening, {utc, Now}) ->
    Left = At - Now,
    SecondsLeft = max(0, Left),
    #{at => Opening, seconds_left => SecondsLeft, due => Left =< 0,
      shown_as => shown_as(SecondsLeft)}.

shown_as(0) ->
    settling_now;
shown_as(Seconds) when Seconds < ?MINUTE ->
    under_a_minute;
shown_as(Seconds) when Seconds < ?HOUR ->
    {minutes, Seconds div ?MINUTE};
shown_as(Seconds) when Seconds < ?DAY ->
    {hours, Seconds div ?HOUR, Seconds rem ?HOUR div ?MINUTE};
shown_as(Seconds) ->
    {days, Seconds div ?DAY, Seconds rem ?DAY div ?HOUR}.
