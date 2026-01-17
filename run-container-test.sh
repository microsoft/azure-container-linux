#!/bin/bash

iptables -I INPUT -p tcp --dport 80 -j ACCEPT
systemctl start containerd
ctr image pull docker.io/library/nginx:latest
ctr run --net-host --rm docker.io/library/nginx:latest nginx
