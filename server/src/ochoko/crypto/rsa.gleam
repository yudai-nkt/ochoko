//// RSA keys, PEM handling and SHA-256 signatures, backed by Erlang's
//// `public_key` module.

/// An RSA private key (an Erlang `RSAPrivateKey` record).
pub type PrivateKey

/// An RSA public key (an Erlang `RSAPublicKey` record).
pub type PublicKey

@external(erlang, "ochoko_rsa_ffi", "generate")
pub fn generate(bits: Int) -> PrivateKey

@external(erlang, "ochoko_rsa_ffi", "private_from_pem")
pub fn private_from_pem(pem: String) -> Result(PrivateKey, Nil)

/// Accepts SPKI ("PUBLIC KEY") and PKCS#1 ("RSA PUBLIC KEY") PEM.
@external(erlang, "ochoko_rsa_ffi", "public_from_pem")
pub fn public_from_pem(pem: String) -> Result(PublicKey, Nil)

/// PKCS#1 "RSA PRIVATE KEY" PEM.
@external(erlang, "ochoko_rsa_ffi", "private_to_pem")
pub fn private_to_pem(k: PrivateKey) -> String

/// SPKI "PUBLIC KEY" PEM of the key pair's public half.
@external(erlang, "ochoko_rsa_ffi", "public_pem")
pub fn public_pem(k: PrivateKey) -> String

@external(erlang, "ochoko_rsa_ffi", "sign_sha256")
pub fn sign_sha256(k: PrivateKey, data: BitArray) -> BitArray

@external(erlang, "ochoko_rsa_ffi", "verify_sha256")
pub fn verify_sha256(k: PublicKey, data: BitArray, sig: BitArray) -> Bool
