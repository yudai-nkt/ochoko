-module(ochoko_raw_http_test_ffi).
-export([raw_get/2]).

%% Send a GET with the request target exactly as given (no URL parsing on
%% our side) and return the whole response.
raw_get(Port, Target) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, [<<"GET ">>, Target,
                               <<" HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n">>]),
    Response = recv_all(Socket, <<>>),
    gen_tcp:close(Socket),
    Response.

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} -> recv_all(Socket, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.
