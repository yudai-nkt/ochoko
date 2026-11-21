#!/bin/sh
# Trust the e2e CA in Chromium's NSS store, then run the tests. Node-side
# requests trust it through NODE_EXTRA_CA_CERTS.
set -eu
mkdir -p "$HOME/.pki/nssdb"
certutil -d "sql:$HOME/.pki/nssdb" -N --empty-password 2>/dev/null || true
certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n e2e-root -i /certs/rootCA.pem
exec "$@"
