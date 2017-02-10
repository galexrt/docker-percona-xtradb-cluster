FROM debian:jessie
MAINTAINER Alexander Trost aka <galexrt@googlemail.com>

ENV PERCONA_MAJOR 5.7 PERCONA_VERSION 5.7.16-27.19-1.jessie DEBIAN_FRONTEND noninteractive

RUN groupadd -r mysql && useradd -r -g mysql mysql && \
    apt-get update && apt-get install -y --no-install-recommends \
		apt-transport-https ca-certificates \
		pwgen wget && \
    wget https://repo.percona.com/apt/percona-release_0.1-4.jessie_all.deb && \
    dpkg -i percona-release_0.1-4.jessie_all.deb && \
	rm percona-release_0.1-4.jessie_all.deb && \
	# also, we set debconf keys to make APT a little quieter
    apt-get update && \
	apt-get install -y --force-yes percona-xtradb-cluster-57 curl && \
	rm -rf /var/lib/apt/lists/* && \
	# purge and re-create /var/lib/mysql with appropriate ownership
	rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld && \
	chown -R mysql:mysql /var/lib/mysql /var/run/mysqld && \
	# ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
	chmod 777 /var/run/mysqld && \
	# comment out a few problematic configuration values
	# don't reverse lookup hostnames, they are usually another container
    sed -Ei 's/^(bind-address|log)/#&/' /etc/mysql/my.cnf && \
	# comment out any "user" entires in the MySQL config ("docker-entrypoint.sh" or "--user" will handle user switching)
	sed -ri 's/^user\s/user = mysql/' /etc/mysql/my.cnf && \
	echo 'skip-host-cache\nskip-name-resolve' | awk '{ print } $1 == "[mysqld]" && c == 0 { c = 1; system("cat") }' /etc/mysql/my.cnf > /tmp/my.cnf && \
	mv /tmp/my.cnf /etc/mysql/my.cnf && \
	sed -Ei '/log-error/s/^/#/g' -i /etc/mysql/my.cnf

COPY jq /usr/bin/jq
COPY clustercheckcron /usr/bin/clustercheckcron
COPY entrypoint.sh /entrypoint.sh

EXPOSE 3306 4567 4568

VOLUME ["/var/lib/mysql", "/var/log/mysql"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["mysqld"]
