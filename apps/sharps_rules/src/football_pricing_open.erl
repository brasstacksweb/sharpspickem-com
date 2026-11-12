-module(football_pricing_open).

-rule("§7").

-export([next/1]).

-define(COMMITTEE_FIRST_WEEK, 11).

-define(TUESDAY, 2).

-type utc() :: {utc, integer()}.

-type league_time() :: {league_local, calendar:datetime()}.

-type snapshot() :: #{
    scheduled := utc() | not_scheduled,
    week := pos_integer(),
    last_game := league_time() | no_game,
    now := league_time(),
    open_time := {0..23, 0..59}
}.

-spec next(snapshot()) -> {exact, utc()} | {estimated, league_time()}.
next(#{scheduled := {utc, _At} = Scheduled}) ->
    {exact, Scheduled};
next(#{scheduled := not_scheduled, week := Week, last_game := LastGame,
       now := {league_local, Now}, open_time := {Hour, Minute}}) ->
    PollDay = poll_day(Week, day_of(LastGame, Now)),
    {estimated, {league_local, not_behind(Now, {next_day(PollDay), {Hour, Minute, 0}})}}.

day_of(no_game, {Today, _Time}) -> Today;
day_of({league_local, {Played, _Time}}, _Now) -> Played.

poll_day(Week, LastGameDay) when Week >= ?COMMITTEE_FIRST_WEEK ->
    first_tuesday_from(LastGameDay);
poll_day(_Week, LastGameDay) ->
    next_day(LastGameDay).

first_tuesday_from(Day) ->
    case calendar:day_of_the_week(Day) of
        ?TUESDAY -> Day;
        _NotTuesday -> first_tuesday_from(next_day(Day))
    end.

not_behind(Now, {Day, Time} = Open) when Open =< Now ->
    not_behind(Now, {next_day(Day), Time});
not_behind(_Now, Open) ->
    Open.

next_day(Day) ->
    calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Day) + 1).
