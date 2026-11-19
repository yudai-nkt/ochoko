-module(ochoko_test_ffi).
-export([temp_path/0]).

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
