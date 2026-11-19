import gleam/string
import ochoko/crypto/rsa

// Key generation is slow, so share one key across tests.
fn key() -> rsa.PrivateKey {
  rsa.generate(2048)
}

pub fn sign_verify_roundtrip_test() {
  let k = key()
  let assert Ok(public) = rsa.public_from_pem(rsa.public_pem(k))
  let sig = rsa.sign_sha256(k, <<"hello":utf8>>)
  assert rsa.verify_sha256(public, <<"hello":utf8>>, sig)
}

pub fn verify_rejects_tampered_data_test() {
  let k = key()
  let assert Ok(public) = rsa.public_from_pem(rsa.public_pem(k))
  let sig = rsa.sign_sha256(k, <<"hello":utf8>>)
  assert !rsa.verify_sha256(public, <<"hellO":utf8>>, sig)
}

pub fn pem_roundtrip_test() {
  let k = key()
  let pem = rsa.private_to_pem(k)
  let assert Ok(k2) = rsa.private_from_pem(pem)
  // PKCS#1 RSASSA-PKCS1-v1_5 signatures are deterministic.
  assert rsa.sign_sha256(k, <<"x":utf8>>) == rsa.sign_sha256(k2, <<"x":utf8>>)
  assert string.starts_with(rsa.public_pem(k), "-----BEGIN PUBLIC KEY-----")
  let assert Ok(_) = rsa.public_from_pem(rsa.public_pem(k))
}

pub fn public_from_pem_accepts_pkcs1_test() {
  let k = key()
  let pkcs1 = pkcs1_public_pem(k)
  assert string.starts_with(pkcs1, "-----BEGIN RSA PUBLIC KEY-----")
  let assert Ok(public) = rsa.public_from_pem(pkcs1)
  assert rsa.verify_sha256(
    public,
    <<"d":utf8>>,
    rsa.sign_sha256(k, <<"d":utf8>>),
  )
}

pub fn private_from_pem_accepts_pkcs8_test() {
  let k = key()
  let assert Ok(k2) = rsa.private_from_pem(pkcs8_private_pem(k))
  assert rsa.sign_sha256(k, <<"x":utf8>>) == rsa.sign_sha256(k2, <<"x":utf8>>)
}

pub fn from_pem_garbage_test() {
  assert rsa.private_from_pem("nope") == Error(Nil)
  assert rsa.public_from_pem("nope") == Error(Nil)
}

@external(erlang, "ochoko_rsa_test_ffi", "pkcs1_public_pem")
fn pkcs1_public_pem(k: rsa.PrivateKey) -> String

@external(erlang, "ochoko_rsa_test_ffi", "pkcs8_private_pem")
fn pkcs8_private_pem(k: rsa.PrivateKey) -> String
