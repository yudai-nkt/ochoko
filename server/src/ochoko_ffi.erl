-module(ochoko_ffi).
-export([unique_positive/0, read_password/0, probe_listen/2, with_lock/3]).

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
            io:get_line("");
        unknown ->
            io:format(standard_error,
                      "warning: cannot disable echo; input will be visible~n", []),
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
    catch _:_ -> unknown
    end.

%% Check that Port can be bound on Interface, then release it again.
probe_listen(Interface, Port) ->
    case inet:parse_address(unicode:characters_to_list(Interface)) of
        {error, _} -> {error, <<"invalid interface">>};
        {ok, Ip} ->
            case gen_tcp:listen(Port, [{ip, Ip}, {reuseaddr, true}]) of
                {ok, Socket} -> gen_tcp:close(Socket), {ok, nil};
                {error, Reason} ->
                    {error, unicode:characters_to_binary(atom_to_list(Reason))}
            end
    end.

%% Runs Fun while holding the node-wide lock Name, waiting up to TimeoutMs
%% for it. Returns {ok, Result} or {error, nil} if the lock stayed busy. The
%% lock is released when Fun returns or raises, or if the caller dies.
with_lock(Name, TimeoutMs, Fun) ->
    Id = {{ochoko_lock, Name}, self()},
    case acquire(Id, TimeoutMs) of
        false -> {error, nil};
        true ->
            try {ok, Fun()}
            after global:del_lock(Id, [node()])
            end
    end.

acquire(Id, TimeoutMs) ->
    case global:set_lock(Id, [node()], 0) of
        true -> true;
        false when TimeoutMs =< 0 -> false;
        false ->
            timer:sleep(min(TimeoutMs, 20)),
            acquire(Id, TimeoutMs - 20)
    end.
