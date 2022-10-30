#!/bin/bash

function check_ip() {
    IP=$1
    VALID_CHECK=$(echo $IP | awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{print "yes"}')
    if echo $IP | grep -E "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$" >/dev/null; then
        if [ ${VALID_CHECK:-no} == "yes" ]; then
            return 0
        else
            return -1
        fi
    else
        return -1
    fi
}

update_nginx_conf() {
    current_nginx_conf_file=$(cat /etc/nginx/current_nginx_conf)
    nginx_conf_localssd=nginx_localssd.conf
    nginx_conf_bypass=nginx_bypass.conf
    source /mnt/gcs/global_conf
    if [ $current_nginx_conf_file != $nginx_conf_localssd ]; then
        echo 'nginx localssd conf file name changed. check if new file exists'
        if [ -e /mnt/gcs/$nginx_conf_localssd ]; then
            echo "file $nginx_conf_localssd exists, check if valid"
            ln -sf /mnt/gcs/$nginx_conf_localssd /etc/nginx/nginx.conf
            check_valid=$(nginx -t 2>&1 | grep "successful")
            if [ -n "$check_valid" ]; then
                echo "file $nginx_conf_localssd valid, reload nginx"
                service nginx reload
                echo $nginx_conf_localssd >/etc/nginx/current_nginx_conf
                gcloud logging write nginx-conf $(hostname)": nginx conf file /mnt/gcs/$nginx_conf_localssd reloaded"
            else
                ln -sf /mnt/gcs/$current_nginx_conf_file /etc/nginx/nginx.conf
                echo "file $nginx_conf_localssd NOT valid, will NOT reload nginx"
                gcloud logging write nginx-conf $(hostname)": nginx conf file /mnt/gcs/$nginx_conf_localssd NOT valid by niginx -t check" --severity=ERROR
            fi
        else
            echo "file /mnt/gcs/$nginx_conf_localssd NOT exists, please check key nginx_conf_localssd in /mnt/gcs/global_conf file"
            gcloud logging write nginx-conf $(hostname)": nginx conf file /mnt/gcs/$nginx_conf_localssd NOT exists" --severity=ERROR
        fi
    else
        echo 'nginx localssd conf file name not changed'
    fi
}

update_upstream_conf() {
    UPSTREAM_FILE_NAME='/etc/nginx/upstream.conf'

    echo "check ip address list in instance group"

    mig_name=$(curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/created-by' -H 'Metadata-Flavor: Google')
    echo "MIG name: $mig_name"

    gcloud compute instance-groups managed list-instances $mig_name \
        --uri | xargs -I '{}' gcloud compute instances describe '{}' \
        --flatten networkInterfaces \
        --format 'csv[no-heading](networkInterfaces.networkIP)' >/tmp/ipaddr.list

    new_ipaddr=$(sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 /tmp/ipaddr.list | xargs)

    #check if IP is valid is very important because if the gcloud fail or IP invalid, reload nginx will fail
    if [ "$new_ipaddr" = "" ]; then
        echo "no ip address found, exit"
        return
    else
        for ip in $new_ipaddr; do
            check_ip $ip
            result=$?
            if [ "$result" != "0" ]; then
                echo "find invalid ip address $ip from gcloud command line, won't update upstream.conf, exit"
                return
            fi
        done
    fi

    old_ipaddr=$(cat /etc/nginx/nginx_proxy_list)

    if [ "$new_ipaddr" != "$old_ipaddr" ]; then
        echo "nginx proxy server changed, old ip:$old_ipaddr, new ip:$new_ipaddr"
        echo 'upstream cache {' >$UPSTREAM_FILE_NAME
        echo $'\thash $uri consistent;' >>$UPSTREAM_FILE_NAME
        echo $'\tkeepalive 256;' >>$UPSTREAM_FILE_NAME
        echo $'\tkeepalive_timeout 600s;' >>$UPSTREAM_FILE_NAME
        echo $'\tkeepalive_requests 3600;' >>$UPSTREAM_FILE_NAME

        for ip in $new_ipaddr; do
            echo "found ip address in MIG: $ip"
            echo $'\tserver'" $ip:8080;" >>$UPSTREAM_FILE_NAME
        done

        echo $'\tcheck port=8081 interval=5000 rise=2 fall=5 timeout=5000 type=http;' >>$UPSTREAM_FILE_NAME
        echo $'\tcheck_http_send "HEAD / HTTP/1.0\\r\\n\\r\\n";' >>$UPSTREAM_FILE_NAME
        echo $'\tcheck_http_expect_alive http_2xx http_3xx;' >>$UPSTREAM_FILE_NAME
        echo '}' >>$UPSTREAM_FILE_NAME
        echo $new_ipaddr >/etc/nginx/nginx_proxy_list
        service nginx reload
    else
        echo "Nginx proxy server not changed, old ip:$old_ipaddr, new ip:$new_ipaddr"
    fi
}

update_stackdriver_metrics() {
    internal_ip=$(curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip' -H 'Metadata-Flavor: Google')
    ip_list=$(cat /etc/nginx/nginx_proxy_list)
    arr=(${ip_list// / })
    if [ "$internal_ip" = ${arr[0]} ]; then
        echo 'has the first internal ip address, write metrics'
        python3 /mnt/gcs/write_metric.py
    fi
}

update_stackdriver_logging() {
    source /mnt/gcs/global_conf
    if [ "$stackdriver_logging" = "on" ]; then
        echo 'start google-fluentd for stackdriver logging'
        service google-fluentd start
        update_stackdriver_metrics
    else
        echo 'stop google-fluentd for stackdriver logging'
        service google-fluentd stop
    fi
}

exec 1>>/tmp/nginx_update_$(date -d now +%Y%m%d).log 2>&1

echo $(date "+%Y-%m-%d %H:%M:%S")

mount_result=$(df -h | grep /mnt/gcs)
if [[ -z $mount_result ]]; then
    echo 'not mounted, waiting for /mnt/gcs initialized by init_nginx_proxy.sh'
    exit
fi

update_nginx_conf

nginx_type=$(curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/nginx-proxy-type' -H 'Metadata-Flavor: Google')
if [ $nginx_type = 'localssd' ]; then
    update_upstream_conf
fi

update_stackdriver_logging
echo ''
