-module(ochoko_ffi).
-export([unique_positive/0]).

unique_positive() -> erlang:unique_integer([positive]).
