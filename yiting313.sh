#!/bin/bash

# Function to show spinner while commands run
spinner() {
    local pid=$!
    local delay=0.25
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Welcome message
echo "============================================="
echo " Welcome to Dr. Abhishek Cloud Tutorials!    "
echo "============================================="
echo " Setting up Network and HTTP Load Balancers  "
echo " Please like the video and subscribe to the  "
echo " channel if you find this content helpful.   "
echo "---------------------------------------------"
echo ""

# Fetch zone and region with fallback to prompt
echo -n "Detecting default zone and region... "
ZONE=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)
REGION=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
spinner

if [ -z "$ZONE" ]; then
    echo "Could not detect default zone."
    echo "Please enter your preferred zone (e.g., us-central1-a):"
    read -p "Zone: " ZONE
    REGION=${ZONE%-*}
else
    echo "Detected Zone: $ZONE"
    echo "Detected Region: $REGION"
fi
echo ""

# Create web instances
echo "Creating web instances (web1, web2, web3)..."
for i in {1..3}; do
    echo -n "Creating web$i... "
    gcloud compute instances create web$i \
        --zone=$ZONE \
        --machine-type=e2-small \
        --tags=network-lb-tag \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --metadata=startup-script='#!/bin/bash
        apt-get update
        apt-get install apache2 -y
        service apache2 restart
        echo "<h3>Web Server: web'$i'</h3>" | tee /var/www/html/index.html' > /dev/null 2>&1 &
    spinner
    echo "Done"
done
echo ""

# Create firewall rule
echo -n "Creating firewall rule for network load balancer... "
gcloud compute firewall-rules create www-firewall-network-lb \
    --allow tcp:80 \
    --target-tags network-lb-tag > /dev/null 2>&1 &
spinner
echo "Done"
echo ""

# Network Load Balancer Setup
echo "Setting up Network Load Balancer..."
echo -n "Creating static IP address... "
gcloud compute addresses create network-lb-ip-1 \
    --region=$REGION > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating health check... "
gcloud compute http-health-checks create basic-check > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating target pool... "
gcloud compute target-pools create www-pool \
    --region=$REGION \
    --http-health-check basic-check > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Adding instances to target pool... "
gcloud compute target-pools add-instances www-pool \
    --instances web1,web2,web3 \
    --zone=$ZONE > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating forwarding rule... "
gcloud compute forwarding-rules create www-rule \
    --region=$REGION \
    --ports 80 \
    --address network-lb-ip-1 \
    --target-pool www-pool > /dev/null 2>&1 &
spinner
echo "Done"

IPADDRESS=$(gcloud compute forwarding-rules describe www-rule \
    --region=$REGION \
    --format="json" | jq -r .IPAddress)
echo "Network Load Balancer IP: $IPADDRESS"
echo ""

# HTTP Load Balancer Setup
echo "Setting up HTTP Load Balancer..."
echo -n "Creating instance template... "
gcloud compute instance-templates create lb-backend-template \
   --region=$REGION \
   --network=default \
   --subnet=default \
   --tags=allow-health-check \
   --machine-type=e2-medium \
   --image-family=debian-12 \
   --image-project=debian-cloud \
   --metadata=startup-script='#!/bin/bash
     apt-get update
     apt-get install apache2 -y
     a2ensite default-ssl
     a2enmod ssl
     vm_hostname="$(curl -H "Metadata-Flavor:Google" \
     http://169.254.169.254/computeMetadata/v1/instance/name)"
     echo "Page served from: $vm_hostname" | \
     tee /var/www/html/index.html
     systemctl restart apache2' > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating managed instance group... "
gcloud compute instance-groups managed create lb-backend-group \
   --template=lb-backend-template \
   --size=2 \
   --zone=$ZONE > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating health check firewall rule... "
gcloud compute firewall-rules create fw-allow-health-check \
  --network=default \
  --action=allow \
  --direction=ingress \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-check \
  --rules=tcp:80 > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating global IPv4 address... "
gcloud compute addresses create lb-ipv4-1 \
  --ip-version=IPV4 \
  --global > /dev/null 2>&1 &
spinner
echo "Done"

LB_IP=$(gcloud compute addresses describe lb-ipv4-1 \
  --format="get(address)" \
  --global)
echo "HTTP Load Balancer IP: $LB_IP"

echo -n "Creating HTTP health check... "
gcloud compute health-checks create http http-basic-check \
  --port 80 > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating backend service... "
gcloud compute backend-services create web-backend-service \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=http-basic-check \
  --global > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Adding backend to service... "
gcloud compute backend-services add-backend web-backend-service \
  --instance-group=lb-backend-group \
  --instance-group-zone=$ZONE \
  --global > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating URL map... "
gcloud compute url-maps create web-map-http \
    --default-service web-backend-service > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating target HTTP proxy... "
gcloud compute target-http-proxies create http-lb-proxy \
    --url-map web-map-http > /dev/null 2>&1 &
spinner
echo "Done"

echo -n "Creating forwarding rule... "
gcloud compute forwarding-rules create http-content-rule \
    --address=lb-ipv4-1 \
    --global \
    --target-http-proxy=http-lb-proxy \
    --ports=80 > /dev/null 2>&1 &
spinner
echo "Done"
echo ""

# Completion message
echo "============================================="
echo " Setup Complete!                            "
echo "============================================="
echo " Network Load Balancer IP: $IPADDRESS"
echo " HTTP Load Balancer IP: $LB_IP"
echo ""
echo " Thank you for following along with Dr. Abhishek's"
echo " Cloud Tutorial! Don't forget to like the video"
echo " and subscribe to the channel for more content!"
echo "============================================="
