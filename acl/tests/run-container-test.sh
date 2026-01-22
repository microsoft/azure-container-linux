#!/bin/bash

iptables -I INPUT -p tcp --dport 80 -j ACCEPT
ctr image pull docker.io/library/nginx:latest
ctr run --detach --net-host docker.io/library/nginx:latest nginx
sleep 2
