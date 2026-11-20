#!/bin/sh
# Trust the e2e CA, then run the driver.
set -eu
cp /certs/rootCA.pem /usr/local/share/ca-certificates/e2e-root.crt
update-ca-certificates >/dev/null
exec "$@"
