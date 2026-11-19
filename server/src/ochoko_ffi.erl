-module(ochoko_ffi).
-export([unique_positive/0, read_password/0]).

unique_positive() -> erlang:unique_integer([positive]).

%% Read a password from stdin: without echo on a terminal, else one line.
%% Returns {ok, Binary} (trailing line break removed) or {error, nil}.
read_password() ->
    Raw = case is_tty() of
        true ->
            Pw = io:get_password(),
            io:nl(),
            Pw;
        false ->
            io:get_line("")
    end,
    case Raw of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        Chars ->
            Bin = unicode:characters_to_binary(Chars),
            {ok, string:trim(Bin, trailing, "\r\n")}
    end.

is_tty() ->
    try prim_tty:isatty(stdin) of
        true -> true;
        _ -> false
    catch _:_ -> false
    end.
