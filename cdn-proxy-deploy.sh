#configuration of project and region, zone
PROJECT_ID=<you project id>
LOCALSSD_ZONE=asia-east2-a
BYPASS_PROXY_REGION=asia-east1
CONFIG_BUCKET_NAME=<your configuration GCS bucket>

IMAGE_NAME=<your image name>
MACHINE_TYPE=n2d-standard-2
HEALTHCHECK_NAME=cdn-nginx-healthcheck
PROXY_FIREWALL_RULE_NAME=cdn-nginx-proxy-rule

UPSTREAM_ENDPOINT=https://storage.googleapis.com
UPSTREAM_HOSTNAME=storage.googleapis.com

#configration local ssd nginx proxy
LOCALSSD_MIG_NAME=nginx-localssd-proxy #name of managed instance group for local ssd
LOCALSSD_TEMPLATE_NAME=$LOCALSSD_MIG_NAME
LOCALSSD_BASE_INSTANCE_NAME=$LOCALSSD_MIG_NAME
LOCALSSD_INSTANCE_NUM=2
LOCALSSD_PER_INSTANCE=2 #375 GB per disk

#configration bypass nginx proxy
BYPASS_MIG_NAME=nginx-bypass-proxy #name of managed instance group for nginx bypass proxy
BYPASS_TEMPLATE_NAME=$BYPASS_MIG_NAME
BYPASS_BASE_INSTANCE_NAME=$BYPASS_MIG_NAME
BYPASS_MIG_INSTANCE_MIN=1
BYPASS_MIG_INSTANCE_MAX=16

#configuration of LB
LB_NAME=lb-cdn-nginx-proxy
LB_PUBLIC_IP_NAME=public-ip-cdn-lcoal-storage
LB_BACKEND_NAME=backend-nginx-proxy

gcloud config set project $PROJECT_ID

if [ $1 = 'create' ]; then

    LOCAL_SSD_STR=''
    for i in $(seq 1 $LOCALSSD_PER_INSTANCE); do
        LOCAL_SSD_STR="$LOCAL_SSD_STR --local-ssd=interface=NVME "
    done

    gcloud beta compute health-checks create http $HEALTHCHECK_NAME \
        --port=8081 \
        --request-path=/index.html \
        --proxy-header=NONE \
        --no-enable-logging \
        --check-interval=5 \
        --timeout=5 \
        --unhealthy-threshold=3 \
        --healthy-threshold=1

    gcloud compute firewall-rules create $PROXY_FIREWALL_RULE_NAME \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:80,tcp:8080,tcp:8081 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=http-server,https-server

    #create lcoal ssd nginx instance group
    gcloud beta compute instance-templates create $LOCALSSD_TEMPLATE_NAME \
        --machine-type=$MACHINE_TYPE \
        --network-interface=network=default,network-tier=PREMIUM,address='' \
        --metadata=cdn-config-bucket=$CONFIG_BUCKET_NAME,nginx-proxy-type=localssd,upstream_endpoint=$UPSTREAM_ENDPOINT,upstream_hostname=$UPSTREAM_HOSTNAME \
        --maintenance-policy=TERMINATE \
        --provisioning-model=STANDARD \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --tags=http-server,https-server \
        --create-disk=auto-delete=yes,boot=yes,device-name=$LOCALSSD_TEMPLATE_NAME,image=projects/$PROJECT_ID/global/images/$IMAGE_NAME,mode=rw,size=100,type=pd-balanced \
        --min-cpu-platform=AMD\ Milan \
        $LOCAL_SSD_STR

    gcloud beta compute instance-groups managed create $LOCALSSD_MIG_NAME \
        --base-instance-name=$LOCALSSD_BASE_INSTANCE_NAME \
        --size=$LOCALSSD_INSTANCE_NUM \
        --template=$LOCALSSD_TEMPLATE_NAME \
        --zone=$LOCALSSD_ZONE \
        --health-check=$HEALTHCHECK_NAME \
        --stateful-internal-ip=interface-name=nic0,auto-delete=on-permanent-instance-deletion \
        --initial-delay=120

    gcloud compute instance-groups set-named-ports $LOCALSSD_MIG_NAME \
        --named-ports http:80 \
        --zone=$LOCALSSD_ZONE

    gcloud beta compute instance-groups managed set-autoscaling $LOCALSSD_MIG_NAME \
        --zone=$LOCALSSD_ZONE \
        --cool-down-period=60 \
        --max-num-replicas=$LOCALSSD_INSTANCE_NUM \
        --min-num-replicas=$LOCALSSD_INSTANCE_NUM \
        --mode=off \
        --target-cpu-utilization=0.6

    #create bypass nginx instance group
    gcloud compute instance-templates create $BYPASS_TEMPLATE_NAME \
        --machine-type=$MACHINE_TYPE \
        --network-interface=network=default,network-tier=PREMIUM,address='' \
        --metadata=cdn-config-bucket=$CONFIG_BUCKET_NAME,nginx-proxy-type=bypass,upstream_endpoint=$UPSTREAM_ENDPOINT,upstream_hostname=$UPSTREAM_HOSTNAME \
        --maintenance-policy=MIGRATE \
        --provisioning-model=STANDARD \
        --scopes=https://www.googleapis.com/auth/cloud-platform \
        --tags=http-server,https-server \
        --create-disk=auto-delete=yes,boot=yes,device-name=$BYPASS_TEMPLATE_NAME,image=projects/$PROJECT_ID/global/images/$IMAGE_NAME,mode=rw,size=50,type=pd-balanced

    gcloud beta compute instance-groups managed create $BYPASS_MIG_NAME \
        --base-instance-name=$BYPASS_BASE_INSTANCE_NAME \
        --size=1 \
        --template=$BYPASS_TEMPLATE_NAME \
        --region=$BYPASS_PROXY_REGION \
        --health-check=$HEALTHCHECK_NAME \
        --initial-delay=120

    gcloud compute instance-groups set-named-ports $BYPASS_MIG_NAME \
        --named-ports http:80 \
        --region=$BYPASS_PROXY_REGION

    gcloud beta compute instance-groups managed set-autoscaling $BYPASS_MIG_NAME \
        --region=$BYPASS_PROXY_REGION \
        --cool-down-period=60 \
        --max-num-replicas=$BYPASS_MIG_INSTANCE_MAX \
        --min-num-replicas=$BYPASS_MIG_INSTANCE_MIN \
        --mode=on \
        --target-cpu-utilization=0.6

    gcloud compute addresses create $LB_PUBLIC_IP_NAME \
        --ip-version=IPV4 \
        --network-tier=PREMIUM \
        --global

    gcloud compute backend-services create $LB_BACKEND_NAME \
        --load-balancing-scheme=EXTERNAL \
        --protocol=HTTP \
        --port-name=http \
        --health-checks=$HEALTHCHECK_NAME \
        --enable-cdn \
        --cache-mode=FORCE_CACHE_ALL \
        --global

    gcloud compute backend-services add-backend $LB_BACKEND_NAME \
        --instance-group=$LOCALSSD_MIG_NAME \
        --instance-group-zone=$LOCALSSD_ZONE \
        --balancing-mode=UTILIZATION \
        --max-utilization=0.8 \
        --capacity-scaler=1 \
        --global

    gcloud compute backend-services add-backend $LB_BACKEND_NAME \
        --instance-group=$BYPASS_MIG_NAME \
        --instance-group-region=$BYPASS_PROXY_REGION \
        --balancing-mode=UTILIZATION \
        --max-utilization=0.8 \
        --capacity-scaler=0.01 \
        --global

    gcloud compute url-maps create $LB_NAME \
        --default-service $LB_BACKEND_NAME

    gcloud compute target-http-proxies create "$LB_NAME-target-proxy" \
        --url-map=$LB_NAME

    gcloud compute forwarding-rules create "$LB_NAME-forwarding-rule" \
        --load-balancing-scheme=EXTERNAL \
        --address=$LB_PUBLIC_IP_NAME \
        --global \
        --target-http-proxy="$LB_NAME-target-proxy" \
        --ports=80
elif [ $1 = 'clean' ]; then
    gcloud compute forwarding-rules delete "$LB_NAME-forwarding-rule" --global --quiet
    gcloud compute target-http-proxies delete "$LB_NAME-target-proxy" --global --quiet
    gcloud compute url-maps delete $LB_NAME --global --quiet
    gcloud compute backend-services delete $LB_BACKEND_NAME --global --quiet
    gcloud compute addresses delete $LB_PUBLIC_IP_NAME --global --quiet
    gcloud compute instance-groups managed delete $LOCALSSD_MIG_NAME --zone=$LOCALSSD_ZONE --quiet
    gcloud compute instance-templates delete $LOCALSSD_TEMPLATE_NAME --quiet
    gcloud compute instance-groups managed delete $BYPASS_MIG_NAME --region=$BYPASS_PROXY_REGION --quiet
    gcloud compute instance-templates delete $BYPASS_TEMPLATE_NAME --quiet
    gcloud beta compute health-checks delete $HEALTHCHECK_NAME --quiet
    gcloud compute firewall-rules delete $PROXY_FIREWALL_RULE_NAME --quiet
else
    echo 'unkown parameter, pelase use create or clean'
fi
