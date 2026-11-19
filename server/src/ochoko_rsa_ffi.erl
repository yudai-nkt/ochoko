-module(ochoko_rsa_ffi).
-export([generate/1, private_from_pem/1, public_from_pem/1,
         private_to_pem/1, public_pem/1, sign_sha256/2, verify_sha256/3]).

-include_lib("public_key/include/public_key.hrl").

generate(Bits) ->
    public_key:generate_key({rsa, Bits, 65537}).

private_from_pem(Pem) ->
    try public_key:pem_decode(Pem) of
        [Entry | _] ->
            case public_key:pem_entry_decode(Entry) of
                #'RSAPrivateKey'{} = Key -> {ok, Key};
                _ -> error_nil()
            end;
        [] -> error_nil()
    catch _:_ -> error_nil()
    end.

public_from_pem(Pem) ->
    try public_key:pem_decode(Pem) of
        [Entry | _] ->
            case public_key:pem_entry_decode(Entry) of
                #'RSAPublicKey'{} = Key -> {ok, Key};
                _ -> error_nil()
            end;
        [] -> error_nil()
    catch _:_ -> error_nil()
    end.

private_to_pem(#'RSAPrivateKey'{} = Key) ->
    Entry = public_key:pem_entry_encode('RSAPrivateKey', Key),
    public_key:pem_encode([Entry]).

public_pem(#'RSAPrivateKey'{modulus = N, publicExponent = E}) ->
    Entry = public_key:pem_entry_encode('SubjectPublicKeyInfo',
                                        #'RSAPublicKey'{modulus = N, publicExponent = E}),
    public_key:pem_encode([Entry]).

sign_sha256(Key, Data) ->
    public_key:sign(Data, sha256, Key).

verify_sha256(Key, Data, Sig) ->
    try public_key:verify(Data, sha256, Sig, Key)
    catch _:_ -> false
    end.

error_nil() -> {error, nil}.
