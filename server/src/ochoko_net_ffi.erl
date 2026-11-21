-module(ochoko_net_ffi).
-export([is_blocked_ip_literal/1]).

%% True when Host (a binary, IPv6 optionally in brackets) is an IP address
%% literal in a loopback, private, link-local, unspecified, shared (CGNAT),
%% multicast or reserved range. Names that are not IP literals give false.
%% inet:parse_address/1 also accepts the short and decimal IPv4 forms
%% ("127.1", "2130706433") that the HTTP client would connect to.
is_blocked_ip_literal(Host) ->
    Trimmed = string:trim(Host, both, "[]"),
    case inet:parse_address(unicode:characters_to_list(Trimmed)) of
        {ok, Ip} -> blocked(Ip);
        {error, _} -> false
    end.

blocked({A, B, _, _}) ->
    A =:= 0 orelse A =:= 10 orelse A =:= 127
        orelse (A =:= 100 andalso B >= 64 andalso B =< 127)
        orelse (A =:= 169 andalso B =:= 254)
        orelse (A =:= 172 andalso B >= 16 andalso B =< 31)
        orelse (A =:= 192 andalso B =:= 168)
        orelse A >= 224;
%% Unspecified and loopback.
blocked({0, 0, 0, 0, 0, 0, 0, 0}) -> true;
blocked({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
%% IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d).
blocked({0, 0, 0, 0, 0, 16#ffff, G, H}) -> blocked(v4(G, H));
blocked({0, 0, 0, 0, 0, 0, G, H}) -> blocked(v4(G, H));
%% NAT64 (64:ff9b::/96) embeds an IPv4 address too.
blocked({16#64, 16#ff9b, 0, 0, 0, 0, G, H}) -> blocked(v4(G, H));
blocked({A, _, _, _, _, _, _, _}) ->
    %% fc00::/7 unique local, fe80::/10 link-local, fec0::/10 site-local,
    %% ff00::/8 multicast.
    (A band 16#fe00) =:= 16#fc00
        orelse (A band 16#ffc0) =:= 16#fe80
        orelse (A band 16#ffc0) =:= 16#fec0
        orelse (A band 16#ff00) =:= 16#ff00.

v4(G, H) -> {G bsr 8, G band 255, H bsr 8, H band 255}.
