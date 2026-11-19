#!/bin/sh
set -eu
umask 077

root=$1
mkdir -p "$root/client" "$root/public" "$root/server"
chmod 700 "$root" "$root/client" "$root/public" "$root/server"

for key in "$root/client/client" "$root/server/ssh_host_ed25519_key"; do
    if [ ! -e "$key" ]; then
        # A lost private key must not silently rotate an existing identity.
        if [ -e "$key.pub" ]; then
            echo "Missing SSH private key: $key" >&2
            exit 1
        fi
        ssh-keygen -q -t ed25519 -N '' -f "$key"
    fi
    [ -f "$key" ] && [ ! -L "$key" ]
    chmod 600 "$key"
    ssh-keygen -y -P '' -f "$key" > "$key.pub.tmp"
    mv -f "$key.pub.tmp" "$key.pub"
done

cp "$root/client/client.pub" "$root/public/jms-executor.pub.tmp"
mv -f "$root/public/jms-executor.pub.tmp" "$root/public/jms-executor.pub"
# Pin the locally generated host key, without trusting a network key scan.
printf '[ansible-executor]:2222 %s\n' "$(cat "$root/server/ssh_host_ed25519_key.pub")" \
    > "$root/client/known_hosts.tmp"
mv -f "$root/client/known_hosts.tmp" "$root/client/known_hosts"
