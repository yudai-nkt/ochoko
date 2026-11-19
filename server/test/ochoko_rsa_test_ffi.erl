-module(ochoko_rsa_test_ffi).
-export([pkcs1_public_pem/1, pkcs8_private_pem/1]).

-include_lib("public_key/include/public_key.hrl").

pkcs1_public_pem(#'RSAPrivateKey'{modulus = N, publicExponent = E}) ->
    Entry = public_key:pem_entry_encode('RSAPublicKey',
                                        #'RSAPublicKey'{modulus = N, publicExponent = E}),
    public_key:pem_encode([Entry]).

pkcs8_private_pem(#'RSAPrivateKey'{} = Key) ->
    Entry = public_key:pem_entry_encode('PrivateKeyInfo', Key),
    public_key:pem_encode([Entry]).
