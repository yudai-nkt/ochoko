-module(ochoko_html_ffi).
-export([parse/1]).

%% Parses an HTML fragment with mochiweb_html and converts the result to
%% Gleam's `Node` type: {element, Tag, [{Name, Value}], [Node]} | {text, Bin}.
%% Comments, processing instructions and doctypes are dropped. Returns
%% {ok, Node} or {error, nil} when the parser rejects the input.
parse(Html) ->
    try
        {ok, convert(mochiweb_html:parse(Html))}
    catch
        _:_ -> {error, nil}
    end.

convert({Tag, Attrs, Children}) when is_binary(Tag) ->
    {element, Tag,
     [{to_bin(K), to_bin(V)} || {K, V} <- Attrs],
     convert_children(Children)};
convert(Bin) when is_binary(Bin) ->
    {text, Bin}.

convert_children(Children) ->
    lists:flatmap(
      fun(C) when is_binary(C) -> [convert(C)];
         ({T, _, _} = C) when is_binary(T) -> [convert(C)];
         (_) -> []
      end,
      Children).

to_bin(B) when is_binary(B) -> B;
to_bin(_) -> <<>>.
