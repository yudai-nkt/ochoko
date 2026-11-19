-module(ochoko_http_date_ffi).
-export([format/1, parse/1]).

format(Seconds) ->
    %% httpd_util:rfc1123_date/1 interprets its argument as local time, so
    %% format by hand to stay in UTC regardless of the host timezone.
    {{Y, Mo, D}, {H, Mi, S}} = calendar:gregorian_seconds_to_datetime(
        Seconds + calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})),
    Days = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"},
    Months = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"},
    Day = element(calendar:day_of_the_week(Y, Mo, D), Days),
    iolist_to_binary(io_lib:format("~s, ~2..0w ~s ~4..0w ~2..0w:~2..0w:~2..0w GMT",
                                   [Day, D, element(Mo, Months), Y, H, Mi, S])).

parse(String) ->
    try
        {{Y, Mo, D}, {H, Mi, S}} = DateTime = httpd_util:convert_request_date(binary_to_list(String)),
        true = calendar:valid_date(Y, Mo, D),
        true = H >= 0 andalso H =< 23 andalso Mi >= 0 andalso Mi =< 59
            andalso S >= 0 andalso S =< 59,
        Seconds = calendar:datetime_to_gregorian_seconds(DateTime)
            - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
        {ok, Seconds}
    catch _:_ -> {error, nil}
    end.
