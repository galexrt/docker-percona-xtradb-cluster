#!/bin/bash

if [ -z "$1" ]; then
    echo "No Kubernetes namespace given. Exiting .."
    exit 2
fi

mkdir certs || exit 1
cd certs || exit 1

# Create CA cert and key
openssl genrsa -out ca-key.pem 4096
openssl req -new -x509 -nodes -days 365000 \
    -key ca-key.pem -out ca-cert.pem

# Create server cert
openssl req -newkey rsa:4096 -days 365000 \
    -nodes -keyout server-key.pem -out server-req.pem
openssl rsa -in server-key.pem -out server-key.pem
openssl x509 -req -in server-req.pem -days 365000 \
    -CA ca-cert.pem -CAkey ca-key.pem -set_serial 01 \
    -out server-cert.pem

# Create client cert
openssl req -newkey rsa:2048 -days 365000 \
    -nodes -keyout client-key.pem -out client-req.pem
openssl rsa -in client-key.pem -out client-key.pem
openssl x509 -req -in client-req.pem -days 365000 \
    -CA ca-cert.pem -CAkey ca-key.pem -set_serial 01 \
    -out client-cert.pem

kubectl create secret mysql-pxc-cert --namespace="$1" --from-file=ca-cert.pem --from-file=server-key.pem --from-file=server-cert.pem --from-file=client-key.pem --from-file=client-cert.pem
