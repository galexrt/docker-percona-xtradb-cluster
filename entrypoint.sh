#!/bin/bash
#
# Copyright (c) 2017 Alexander Trost
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

function join {
	local IFS="$1"
	shift
	joined=$(tr "$IFS" '\n' <<< "$*" | sort -un | tr '\n' "$IFS")
	echo "${joined%?}"
}

if [ -n "$DEBUG" ]; then
    set -x
fi
set -e
# Extra Galera/MySQL setting envs
wsrep_slave_threads="${WSREP_SLAVE_THREADS:-2}"
PROMETHEUS_EXPORTER_USERNAME="${PROMETHEUS_EXPORTER_USERNAME:-exporter}"
MONITOR_PASSWORD="${MONITOR_PASSWORD:-monitor}"

# if command starts with an option, prepend mysqld path
if [ -z "$1" ] || [ "${1:0:1}" = '-' ]; then
	set -- /usr/sbin/mysqld "$@"
fi

if [ -z "$CLUSTER_NAME" ]; then
	echo >&2 'Error: You need to specify CLUSTER_NAME'
	exit 1
fi
if [ -z "$DISCOVERY_SERVICE" ]; then
	echo >&2 'Error: You need to specify DISCOVERY_SERVICE'
	exit 1
fi

mkdir -p "/var/lib/mysql-files" "$DATADIR"
chown -R mysql:mysql "/var/lib/mysql-files"
# Get datadir config
cd "$DATADIR" || { echo "Can't access data dir '$DATADIR'"; exit 1; }
cd .. || { echo "Can't go down one from the datadir."; exit 1; }
DATADIR="$(mysqld --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }' | sed 's#/$##')"
if [ ! -f "$DATADIR/.init-ok" ] || [ ! -f ".init-ok" ]; then
	if [ -z "$MYSQL_ROOT_PASSWORD" ] && [ -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ] && \
		[ -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
        echo >&2 'Error: Database is uninitialized and password option is not specified '
        echo >&2 '       You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
        exit 1
    fi
	echo "-> Running mysqld --initialize to $DATADIR"
	ls -lah "$DATADIR"
	mysqld --initialize --datadir="$DATADIR"
	chown -R mysql:mysql "$DATADIR"
	chown mysql:mysql /var/log/mysqld.log
	echo "=> Finished mysqld --initialize"
	tempSqlFile="/tmp/mysql-first-time.sql"
	set -- "$@" --init-file="$tempSqlFile"
	echo "" > "$tempSqlFile"
	if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
		MYSQL_ROOT_PASSWORD="$(pwmake 128)"
		echo
		echo "======================================================"
		echo "==> GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD <=="
		echo "======================================================"
		echo
	fi
	# sed is for https://bugs.mysql.com/bug.php?id=20545
	echo "USE mysql;" >> "$tempSqlFile"
	echo "$(mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/')" >> "$tempSqlFile"
	
	# What's done in this file shouldn't be replicated
	# or products like mysql-fabric won't work
	cat >> "$tempSqlFile" <<-EOSQL
		SET @@SESSION.SQL_LOG_BIN=0;
		CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
		CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
		GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;
		GRANT ALL ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
		SET PASSWORD FOR 'root'@'127.0.0.1' = PASSWORD('$MYSQL_ROOT_PASSWORD');
		CREATE USER IF NOT EXISTS 'xtrabackup'@'127.0.0.1' IDENTIFIED BY '$XTRABACKUP_PASSWORD';
		GRANT RELOAD,PROCESS,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'127.0.0.1';
		CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY '$MONITOR_PASSWORD';
		CREATE USER IF NOT EXISTS 'monitor'@'127.0.0.1' IDENTIFIED BY '$MONITOR_PASSWORD';
		GRANT REPLICATION CLIENT ON *.* TO 'monitor'@'%' IDENTIFIED BY '$MONITOR_PASSWORD';
		GRANT PROCESS ON *.* TO 'monitor'@'127.0.0.1' IDENTIFIED BY '$MONITOR_PASSWORD';
		DROP DATABASE IF EXISTS test;
		FLUSH PRIVILEGES;
	EOSQL

	if [ "$MYSQL_DATABASE" ]; then
		echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;" >> "$tempSqlFile"
	fi
	if [ "$MYSQL_USER" ] && [ "$MYSQL_PASSWORD" ]; then
		echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" >> "$tempSqlFile"
		if [ "$MYSQL_DATABASE" ]; then
			echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%';" >> "$tempSqlFile"
		fi
		echo 'FLUSH PRIVILEGES;' >> "$tempSqlFile"
	fi
	if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
		echo "ALTER USER 'root'@'%' PASSWORD EXPIRE;" >> "$tempSqlFile"
	fi
	echo "-> Checking if prometheus user should be added ..."
	if [ ! -z "$PROMETHEUS_EXPORTER" ] && [ ! -z "$PROMETHEUS_EXPORTER_PASSWORD" ] && [ ! -z "$PROMETHEUS_EXPORTER_USERNAME" ]; then
		cat >> "$tempSqlFile" <<-EOSQL
		CREATE USER '$PROMETHEUS_EXPORTER_USERNAME'@'127.0.0.1' IDENTIFIED BY '$PROMETHEUS_EXPORTER_PASSWORD';
		GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '$PROMETHEUS_EXPORTER_USERNAME'@'127.0.0.1' WITH MAX_USER_CONNECTIONS 4;
		FLUSH PRIVILEGES;
		EOSQL
		echo "=> Added Prometheus User."
	fi
	echo "=> MySQL first time init preparation done. Ready to run preparation."
fi
touch ".init-ok"
touch "$DATADIR/.init-ok"
chown -R mysql:mysql "$DATADIR"

echo
echo '-> Registering in the discovery service ...'
echo

# Read the list of registered IP addresses
ipaddr="$(hostname -i | awk '{ print $1 }')"
hostname="$(hostname)"

curl -s "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/queue/$CLUSTER_NAME" -XPOST -d value="$ipaddr" -d ttl=60
# get list of IP from queue
ips1=$(curl -s "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/queue/$CLUSTER_NAME" | jq -r '.node.nodes[].value')

# Register the current IP in the discovery service
# key set to expire in 30 sec. There is a cronjob that should update them regularly
curl -s "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/$ipaddr/ipaddr" -XPUT -d value="$ipaddr" -d ttl=30
curl -s "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/$ipaddr/hostname" -XPUT -d value="$hostname" -d ttl=30
curl -s "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/$ipaddr" -XPUT -d ttl=30 -d dir=true -d prevExist=true

echo
echo "=> Registered with discovery service."
echo

ips2=$(curl -s "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/?quorum=true" | jq -r '.node.nodes[]?.key' | awk -F'/' '{print $(NF)}')
c=0
while [ -z "$ips2" ] && (( c<=30 )); do
	ips2=$(curl -s "http://$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/?quorum=true" | jq -r '.node.nodes[]?.key' | awk -F'/' '{print $(NF)}')
	echo "-> No peers found in discovery. Try $c from 30 ..."
	sleep 1
	(( c++ ))
done
echo
echo "=> Found peers in discovery."
echo
# this remove my ip from the list
cluster_join="$(join , "${ips1[@]/$ipaddr}" "${ips2[@]/$ipaddr}" | sed -r 's/^,|,$//g')"
/usr/bin/clustercheckcron "monitor" "$MONITOR_PASSWORD" 1 /var/log/mysql/clustercheck.log 1 "/etc/mysql/my.cnf" &

echo
echo "-> Will join cluster: $cluster_join ..."
echo

cat > /etc/mysql/conf.d/wsrep.cnf <<EOF
[mysqld]

wsrep_slave_threads = $wsrep_slave_threads
wsrep_cluster_address = gcomm://$cluster_join
wsrep_provider = /usr/lib/galera3/libgalera_smm.so
wsrep_node_address = $ipaddr

wsrep_cluster_name = "$CLUSTER_NAME"

wsrep_sst_method = xtrabackup-v2
wsrep_sst_auth = "xtrabackup:$XTRABACKUP_PASSWORD"
EOF

echo "==> Starting Percona XtraDB server ..."
echo
echo "Executing: $*"
echo

exec "$@"
