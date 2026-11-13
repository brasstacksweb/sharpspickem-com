-module(contribution).

-rule("§3").

-export([request/1, confirm/1, reject/1, cancel/2, reverse/1]).

-export_type([contribution/0, status/0]).

-type units() :: integer().

-type status() :: pending | confirmed | rejected | cancelled | reversed.

-type contribution() :: #{
    owner := term(),
    kind := buy_in | top_up,
    requested_units := units(),
    status := status(),
    confirmed_units => units()
}.

-type found() :: contribution() | not_found.

-spec request(#{season_settled := boolean(), top_ups_enabled := boolean(),
                amount_units := units(), already_pending := boolean()}) ->
    requested
  | {refused, season_settled | top_ups_disabled | amount_below_one_unit | already_pending}.
request(#{season_settled := true}) -> {refused, season_settled};
request(#{top_ups_enabled := false}) -> {refused, top_ups_disabled};
request(#{amount_units := Amount}) when Amount < 1 -> {refused, amount_below_one_unit};
request(#{already_pending := true}) -> {refused, already_pending};
request(#{already_pending := false}) -> requested.

-spec confirm(#{season_settled := boolean(), contribution := found(),
                amount_units := as_requested | units()}) ->
    {confirm, units()}
  | {refused, amount_below_one_unit | season_settled | no_such_contribution
            | {already, status()}}.
confirm(#{amount_units := Amount}) when is_integer(Amount), Amount < 1 ->
    {refused, amount_below_one_unit};
confirm(#{season_settled := true}) ->
    {refused, season_settled};
confirm(#{contribution := not_found}) ->
    {refused, no_such_contribution};
confirm(#{contribution := #{status := pending, requested_units := Requested},
          amount_units := as_requested}) ->
    {confirm, Requested};
confirm(#{contribution := #{status := pending}, amount_units := Amount}) ->
    {confirm, Amount};
confirm(#{contribution := #{status := Status}}) ->
    {refused, {already, Status}}.

-spec reject(found()) -> rejected | unchanged.
reject(#{status := pending}) -> rejected;
reject(_NotPending) -> unchanged.

-spec cancel(Owner :: term(), found()) -> cancelled | unchanged.
cancel(Owner, #{owner := Owner, status := pending}) -> cancelled;
cancel(_Owner, _NotTheirsOrNotPending) -> unchanged.

-spec reverse(#{season_settled := boolean(), contribution := found()}) ->
    {reverse, units()} | {refused, season_settled | only_a_confirmed_contribution}.
reverse(#{season_settled := true}) ->
    {refused, season_settled};
reverse(#{contribution := #{status := confirmed, confirmed_units := Confirmed}}) ->
    {reverse, Confirmed};
reverse(#{contribution := _NotConfirmed}) ->
    {refused, only_a_confirmed_contribution}.
