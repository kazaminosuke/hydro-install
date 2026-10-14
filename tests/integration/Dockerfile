FROM debian:12
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y systemd systemd-sysv docker.io mariadb-server curl git rsync procps python3 iproute2 ca-certificates jq && apt-get clean
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
