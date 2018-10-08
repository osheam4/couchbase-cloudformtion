#!/usr/bin/env bash

echo "Running syncGateway.sh"

stackName=$1

yum -y update
yum -y install jq

#rm -rf /home/sync_gateway/logs
#mkdir -p /opt/sync_gateway/logs
#chown -R sync_gateway:sync_gateway /opt/sync_gateway
#ln -s /opt/sync_gateway/logs /home/sync_gateway/logs

region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
  | jq '.region'  \
  | sed 's/^"\(.*\)"$/\1/' )

instanceID=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
  | jq '.instanceId' \
  | sed 's/^"\(.*\)"$/\1/' )

echo "Using the settings:"
echo region \'$region\'
echo instanceID \'$instanceID\'

#aws ec2 create-tags \
#  --region ${region} \
#  --resources ${instanceID} \
#  --tags Key=Name,Value=${stackName}-SyncGateway

COMPANY=$(aws ec2 describe-instances \
    --region ${region} \
    --query  'Reservations[0].Instances[0]' \
    --instance-ids ${instanceID} \
    | jq '.Tags[] | select( .Key == "Company") | .Value' \
    | sed 's/^"\(.*\)"$/\1/'
)


ENVIRONMENT=$(aws ec2 describe-instances \
    --region ${region} \
    --query 'Reservations[0].Instances[0]' \
    --instance-ids ${instanceID} \
    | jq '.Tags[] | select( .Key == "Environment") | .Value' \
    | sed 's/^"\(.*\)"$/\1/'
)


PROJECT=$(aws ec2 describe-instances \
    --region ${region} \
    --query 'Reservations[0].Instances[0]' \
    --instance-ids ${instanceID} \
    | jq '.Tags[] | select( .Key == "Project") | .Value' \
    | sed 's/^"\(.*\)"$/\1/'
)

couchdbELB="${COMPANY}-${PROJECT}-COUCHDB-${ENVIRONMENT}-ELBV2"

LoadBalancerDNS=$(aws elbv2 describe-load-balancers \
    --region ${region} \
    --names ${couchdbELB} \
    | jq '.LoadBalancers[].DNSName' \
    | sed 's/^"\(.*\)"$/\1/'
)

echo "LoadBalancerDNS ${LoadBalancerDNS}"

file="/home/sync_gateway/sync_gateway.json"
echo '
{
   "interface":":8080",
   "profileInterface":"80",
   "adminInterface":":4985",
   "MaxFileDescriptors":200000,
   "compressResponses": false,
   "log": ["CRUD","CRUD+","HTTP","HTTP+","Access","Cache","Shadow","Shadow+","Changes","Changes+"]
   , "databases": {
     "reference_data": {
       "bucket": "reference_data"
       , "server": "http://'${LoadBalancerDNS}':8091"
       , "users" : {
         "GUEST": {
           "disabled": false, "admin_channels": ["*"]
         }
       }
     }
  }
}
' > ${file}


# Create the reference_data Bucket

output=""
while [[ ! $output =~ "exists" ]]
do
  output=$(curl -s -X POST \
  -u Administrator:couchbase1 \
  http://${LoadBalancerDNS}:8091/pools/default/buckets \
  -d name=reference_data -d ramQuotaMB=512 -d authType=sasl \
  -d replicaNumber=1 -d bucketType=couchbase \
  | jq '.errors.name')
  echo Creating reference_data bucket \'$output\'
  sleep 4
done

chmod 755 ${file}
chown sync_gateway ${file}
chgrp sync_gateway ${file}

# Need to restart to load the changes
service sync_gateway stop
service sync_gateway start
