#!/bin/bash -e

if [ -f "/firstrun.txt" ]; then
    echo "firstrun already executed, continue."
    exit 0
fi

# If the datadir is empty (fresh /srv/mysql bind mount), initialize system tables
if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "Initializing MariaDB system tables..."
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql
    # Start MariaDB now that system tables exist
    systemctl start mariadb
    # Wait for it to be ready
    for i in $(seq 1 30); do
        if mariadb -e "SELECT 1" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi

userpass=$(pwgen)

# output URI/PW for use by app configuration
cat <<EOF> /var/lib/mysql/.creator-mysql-uri.txt
DATABASE_URL="mysql://creator:$userpass@127.0.0.1:3306/creator"
EOF

# create the database and user (use mysql_native_password for TCP/IP auth)
mariadb <<EOF
create database IF NOT EXISTS creator;
CREATE USER IF NOT EXISTS 'creator'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$userpass');
CREATE USER IF NOT EXISTS 'creator'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$userpass');
GRANT ALL PRIVILEGES ON creator.* TO 'creator'@'%';
GRANT ALL PRIVILEGES ON creator.* TO 'creator'@'localhost';
FLUSH PRIVILEGES;
EOF

touch /firstrun.txt