-module(ochoko_test_ffi).
-export([temp_path/0, cell_new/1, cell_get/1, cell_set/2]).

%% A unique, not-yet-existing path under the system temp directory.
temp_path() ->
    Dir = case os:getenv("TMPDIR") of
        false -> "/tmp";
        D -> string:trim(D, trailing, "/")
    end,
    Name = io_lib:format("ochoko_test_~b_~b.sqlite",
                         [erlang:unique_integer([positive]),
                          erlang:system_time(microsecond)]),
    unicode:characters_to_binary(filename:join(Dir, lists:flatten(Name))).

%% Mutable cells for test doubles (an ETS table owned by the calling process).
cell_new(Initial) ->
    T = ets:new(cell, [public]),
    ets:insert(T, {value, Initial}),
    T.

cell_get(T) ->
    [{value, V}] = ets:lookup(T, value),
    V.

cell_set(T, V) ->
    ets:insert(T, {value, V}),
    nil.
