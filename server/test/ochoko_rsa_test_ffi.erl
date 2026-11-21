-module(ochoko_rsa_test_ffi).
-export([cached_key/1, cached_key_named/2, pkcs1_public_pem/1, pkcs8_private_pem/1]).

-include_lib("public_key/include/public_key.hrl").

cached_key(Make) ->
    case persistent_term:get(?MODULE, undefined) of
        undefined ->
            Key = Make(),
            persistent_term:put(?MODULE, Key),
            Key;
        Key -> Key
    end.

cached_key_named(Name, Make) ->
    case persistent_term:get({?MODULE, Name}, undefined) of
        undefined ->
            Key = Make(),
            persistent_term:put({?MODULE, Name}, Key),
            Key;
        Key -> Key
    end.

pkcs1_public_pem(#'RSAPrivateKey'{modulus = N, publicExponent = E}) ->
    Entry = public_key:pem_entry_encode('RSAPublicKey',
                                        #'RSAPublicKey'{modulus = N, publicExponent = E}),
    public_key:pem_encode([Entry]).

pkcs8_private_pem(#'RSAPrivateKey'{} = Key) ->
    Entry = public_key:pem_entry_encode('PrivateKeyInfo', Key),
    public_key:pem_encode([Entry]).
