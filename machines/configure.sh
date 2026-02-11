#!/bin/bash -ex

##
### This script handles the configuration state for a deployment of relay tools.  It assumes that the images have been built or downloaded already.
##

if [ -f ".env" ]; then
    source .env
elif [ -z "$MYDOMAIN" ] && [ -z "$SELF_SIGNED" ]; then
    echo "Please configure a .env file for top level configuration or set MYDOMAIN environment variable"
    echo "MYDOMAIN=root level domain name to use"
    echo "MYEMAIL=<optional> email address for SSL certificate registration"
    echo "-or-"
    echo "for self-signed certificate set:"
    echo "SELF_SIGNED=mydomain.com"
    exit 1
fi

# Launch sequence:

# launch Mysql first.
# configure relaycreator .env
# launch the rest

# on firstrun mysql will drop a credentials URI into /srv/mysql/.creator-mysql-uri.txt
machinectl start mysql

# generate a nostr key for use with API
systemd-nspawn --pipe -M haproxy /bin/bash << EOF
    /usr/local/bin/npub2hex --generate > /srv/relaycreator/.nostrcreds.env
    chmod 0600 /srv/relaycreator/.nostrcreds.env
EOF

# register for SSL certificate with certbot
# for use with: haproxy
# configured in: relaycreator (path), haproxy (bundle.pem file)

if [ -n "$SELF_SIGNED" ]; then
    MYDOMAIN=$SELF_SIGNED
systemd-nspawn --pipe -M haproxy /bin/bash << EOR
    mkdir -p /etc/haproxy/certs
    cd /etc/haproxy/certs

    openssl req -newkey ec:<(openssl ecparam -name secp384r1) -nodes -x509 -keyout ca.key -out ca.pem -days 365000 -subj '/CN=${SELF_SIGNED}/O=MyOrganization/C=US'
    cat ca.key ca.pem > bundle.pem
EOR
    
else

# since haproxy is not started yet, use standalone web mode
# Automatic renewal is handled by certrenew.timer (enabled below after haproxy starts)
systemd-nspawn --pipe -M keys-certs-manager /bin/bash << EOF
    mkdir -p /etc/haproxy/certs

    if [ -z "$MYEMAIL" ]; then
        certbot certonly --config-dir="/etc/haproxy/certs" --work-dir="/etc/haproxy/certs" --logs-dir="/etc/haproxy/certs" -d "$MYDOMAIN" --agree-tos --register-unsafely-without-email --standalone --preferred-challenges http --non-interactive
    else 
        certbot certonly --config-dir="/etc/haproxy/certs" --work-dir="/etc/haproxy/certs" --logs-dir="/etc/haproxy/certs" -d "$MYDOMAIN" --agree-tos -m "$MYEMAIL" --standalone --preferred-challenges http --non-interactive
    fi

    # haproxy needs one file (write to bind mount so haproxy container can see it)
    mkdir -p /srv/haproxy/certs
    cat /etc/haproxy/certs/live/$MYDOMAIN/fullchain.pem /etc/haproxy/certs/live/$MYDOMAIN/privkey.pem > /srv/haproxy/certs/bundle.pem
    chmod 0600 /srv/haproxy/certs/bundle.pem

EOF

fi

echo "$MYDOMAIN"

source /srv/relaycreator/.nostrcreds.env

# wait for mysql configuration to exist (timeout after 120 seconds)
MYSQL_WAIT=0
while [ ! -f "/srv/mysql/.creator-mysql-uri.txt" ]; do
    sleep 1
    MYSQL_WAIT=$((MYSQL_WAIT + 1))
    if [ $MYSQL_WAIT -ge 120 ]; then
        echo "ERROR: MySQL did not initialize within 120 seconds."
        echo "Check: machinectl status mysql"
        exit 1
    fi
done

source /srv/mysql/.creator-mysql-uri.txt

JWT_SECRET=`openssl rand -base64 32`

# Configure relaycreator .env file (Express API server)
cat << EOF > /srv/relaycreator/.env
# Express API server settings
DATABASE_URL=$DATABASE_URL
JWT_SECRET=$JWT_SECRET
PORT=4000
CORS_ORIGIN=https://$MYDOMAIN
DEPLOY_PUBKEY=$NOSTR_PUBLIC_KEY
CREATOR_DOMAIN=$MYDOMAIN
INVOICE_AMOUNT=21
INVOICE_PREMIUM_AMOUNT=2100

# to enable payments you must run LNBITS and set these settings:
PAYMENTS_ENABLED=false
LNBITS_ADMIN_KEY=
LNBITS_INVOICE_READ_KEY=
LNBITS_ENDPOINT=
EOF

# Launch relaycreator
machinectl start relaycreator

# Configure haproxy management daemon (cookiecutter)
cat << EOF > /srv/haproxy/.cookiecutter.env
BASE_URL=https://$MYDOMAIN
PRIVATE_KEY=$NOSTR_PRIVATE_KEY
EOF

# Launch haproxy
machinectl start haproxy

# Enable automatic certificate renewal (skip for self-signed)
if [ -z "$SELF_SIGNED" ]; then
    systemctl daemon-reload
    systemctl enable --now certrenew.timer
    echo "Certificate auto-renewal timer enabled (runs twice daily)"
fi

# Configure strfry management daemon (cookiecutter)
cat << EOF > /srv/strfry/.cookiecutter.env
BASE_URL=https://$MYDOMAIN
PRIVATE_KEY=$NOSTR_PRIVATE_KEY
EOF

cat << EOF > /srv/strfry/.interceptor.env
INTERCEPTOR_CONFIG_URL=https://$MYDOMAIN/api/sconfig/relays
EOF

# Launch strfry
machinectl start strfry

echo "All done!"
