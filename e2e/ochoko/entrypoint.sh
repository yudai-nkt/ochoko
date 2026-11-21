#!/bin/sh
# Trust the e2e CA, create the signing key on first start, then run ochoko.
set -eu
cp /certs/rootCA.pem /usr/local/share/ca-certificates/e2e-root.crt
update-ca-certificates >/dev/null
[ -f /data/ochoko.pem ] || /app/entrypoint.sh run keygen /data/ochoko.pem >/dev/null
exec /app/entrypoint.sh run "$@"
