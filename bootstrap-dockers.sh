#!/usr/bin/env bash
set -eo pipefail

# Load fedservice environment variables
export $(grep -v '^#' .env | xargs)

# Check if NETWORK_NAME is set
if [ -z "${NETWORK_NAME}" ]; then
  echo "Error: NETWORK_NAME is not set. Please ensure it is defined in the environment variables."
  exit 1
fi

FS_NETWORK_NAME=${NETWORK_NAME}
unset NETWORK_NAME
SCRIPT_NAME=$(basename "$0")
TEMP_DIR="/tmp"
TRUST_ANCHOR_JSON="${TEMP_DIR}/trust_anchor.json"
TRUST_MARK_ISSUER_JSON="${TEMP_DIR}/trust_mark_issuer.json"
TRUST_ANCHOR_WL="${TRUST_ANCHOR_URL}/.well-known/openid-federation"
TRUST_MARK_ISSUER_WL="${TRUST_MARK_ISSUER_URL}/.well-known/openid-federation"
WALLET_PROVIDER_WL="${WALLET_PROVIDER_URL}/.well-known/openid-federation"
FLASK_WALLET_WL="${FLASK_WALLET_URL}/"

# Function to check URL reachability
check_url() {
    local url=$1
    if ! curl -k --silent --head --fail "$url" > /dev/null; then
        return 1
    fi
    echo $url
    return 0
}

# Check if running inside the container
if [[ "$INSIDE_BOOTSTRAP_CONTAINER" == "true" ]]; then
  echo "Running container-only section of the script"

  # Place all container-specific commands here
  
  SUB_SERVICES_URL=("${WALLET_PROVIDER_URL}" "${TRUST_MARK_ISSUER_URL}" )

  if [[ -f "/vc_up_and_running/.env" ]]; then
    # Load vc_up_and_running environment variables
    export $(grep -v '^#' /vc_up_and_running/.env | xargs)
    
    # Check if fedservice network name and vc_up_and_running network name are equal
    if [ "${FS_NETWORK_NAME}" != "${NETWORK_NAME}" ]; then
      echo "Error: fedservice network (${FS_NETWORK_NAME}) and vc_up_and_running network (${NETWORK_NAME}) are not equal."
      exit 1
    fi
    
    ISSUER_URL_WL="${ISSUER_URL}/.well-known/openid-federation"
    SUB_SERVICES_URL+=("${ISSUER_URL}")
    echo "Checking Issuer reachability..."
    if ! check_url "$ISSUER_URL_WL"; then
        echo -e "\nExiting due to unreachable Issuer service."
        exit 1
    else
        echo "Issuer services is reachable."
    fi
  fi

  # Fetch trust anchor information and save it to JSON
  python3 /fedservice/dc4eu_federation/get_info.py -k -t "${TRUST_ANCHOR_URL}" > "${TRUST_ANCHOR_JSON}"

  # Add trust anchor
  python3 /fedservice/dc4eu_federation/add_info.py -s "${TRUST_ANCHOR_JSON}" -t trust_mark_issuer/trust_anchors
  python3 /fedservice/dc4eu_federation/add_info.py -s "${TRUST_ANCHOR_JSON}" -t wallet_provider/trust_anchors

  # Remove authority hints and add trust anchor URL
  rm -rf trust_mark_issuer/authority_hints
  printf "${TRUST_ANCHOR_URL}" > trust_mark_issuer/authority_hints
  rm -rf wallet_provider/authority_hints
  printf "${TRUST_ANCHOR_URL}" > wallet_provider/authority_hints

  # Generate issuer info for trust_mark_issuer and add it to trust anchor
  python3 /fedservice/dc4eu_federation/issuer.py trust_mark_issuer > "${TRUST_MARK_ISSUER_JSON}"
  python3 /fedservice/dc4eu_federation/add_info.py -s "${TRUST_MARK_ISSUER_JSON}" -t trust_anchor/trust_mark_issuers

  # Fetch and add subordinates to the trust anchor
  TEMP_FILE="${TEMP_DIR}/service_info.json"
  for SERVICE_URL in "${SUB_SERVICES_URL[@]}"; do
    echo "Add ${SERVICE_URL} as subordinate to the trust anchor"
    python3 /fedservice/dc4eu_federation/get_info.py -k -s "$SERVICE_URL" > "$TEMP_FILE" && \
    python3 /fedservice/dc4eu_federation/add_info.py -s "$TEMP_FILE" -t trust_anchor/subordinates
  done

  mkdir -p flask_wallet/trust_anchors
  cp -a wallet_provider/trust_anchors/* flask_wallet/trust_anchors/

  if [ -z "${ISSUER_URL}" ]; then
    # Convert trust_anchor.json to YAML for Issuer OIDC frontend
    echo -e "\nPlace this into oidc_frontend.yaml:" 
    echo "config:" 
    echo "  op:" 
    echo "    server_info:"
    echo "      authority_hints:"
    echo "      - ${TRUST_ANCHOR_URL}"
    echo "      trust_marks:"
    echo "      - ######  GENERATED TRUST MARKS ######"      
    echo "      trust_anchors:"
    python3 /fedservice/dc4eu_federation/convert_json_to_yaml.py ${TEMP_DIR}/trust_anchor.json | sed 's/^/        /'
    
    exit 0
  fi

  # Path to the JSON and YAML files
  OIDC_YAML_FILE="/vc_up_and_running/satosa/plugins/oidc_frontend.yaml"
  
  TRUST_MARK_EHIC=$(python3 /fedservice/dc4eu_federation/create_trust_mark.py -d trust_mark_issuer/ \
  -m http://dc4eu.example.com/EHICCredential/se -e ${ISSUER_URL})

  TRUST_MARK_PDA1=$(python3 /fedservice/dc4eu_federation/create_trust_mark.py -d trust_mark_issuer/ \
  -m http://dc4eu.example.com/PDA1Credential/se -e ${ISSUER_URL})

  # Update the YAML file by directly assigning the JSON trust anchor data
  python3 - << EOF
import yaml
import json

with open("$OIDC_YAML_FILE", "r") as file:
    data = yaml.safe_load(file)

# Load the new trust anchor data from JSON
with open("$TRUST_ANCHOR_JSON", "r") as json_file:
    trust_anchor_data = json.load(json_file)

print("\nTRUST_MARK_EHIC: $TRUST_MARK_EHIC")
print("\nTRUST_MARK_PDA1: $TRUST_MARK_PDA1")

try:
    data['config']["op"]["server_info"]["trust_marks"] = ["$TRUST_MARK_EHIC", "$TRUST_MARK_PDA1"]
    data['config']["op"]["server_info"]["authority_hints"] = ["$TRUST_ANCHOR_URL"]
    data['config']["op"]["server_info"]["trust_anchors"] = trust_anchor_data
except KeyError:
    print("Error: Expected structure not found in Issuer OIDC config.")
    exit(1)

#Write the updated YAML
with open("$OIDC_YAML_FILE", "w") as file:
    yaml.dump(data, file, sort_keys=False, default_flow_style=False, indent=2)
print("Updated Issuer OIDC config successfully.")
EOF

  # Continue with the rest of the container-specific commands

  # Exit after completing the container-specific tasks
  exit 0
fi


######################################
# --- Host-side code starts here --- #
######################################



COMPOSE_FILE="docker-compose.yaml"
RETRIES=5  # Number of retries for health checks
WAIT_INTERVAL=5  # Seconds to wait between retries
NETWORK_NAME="dc4eu_shared_network"


# Check for Docker and Docker Compose
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker and try again."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "Docker Compose is not installed or not in the PATH. Please install Docker Compose v2 and try again."
    exit 1
fi

mkdir -p log
mkdir -p certificates/flask_wallet
mkdir -p certificates/trust_anchor
mkdir -p certificates/trust_mark_issuer
mkdir -p certificates/wallet_provider
if [ ! -e certificates/privkey.pem ]; then
  printf "Create certificate.\n"
  openssl req -x509 -newkey rsa:4096 -keyout certificates/flask_wallet/privkey.pem -out certificates/flask_wallet/cert+chain.pem -sha256 -days 3650 -nodes --subj "/CN=${FLASK_WALLET_HOST}" -addext "subjectAltName=DNS:${FLASK_WALLET_HOST}"
  openssl req -x509 -newkey rsa:4096 -keyout certificates/trust_anchor/privkey.pem -out certificates/trust_anchor/cert+chain.pem -sha256 -days 3650 -nodes --subj "/CN=${TRUST_ANCHOR_HOST}" -addext "subjectAltName=DNS:${TRUST_ANCHOR_HOST}"
  openssl req -x509 -newkey rsa:4096 -keyout certificates/trust_mark_issuer/privkey.pem -out certificates/trust_mark_issuer/cert+chain.pem -sha256 -days 3650 -nodes --subj "/CN=${TRUST_MARK_ISSUER_HOST}" -addext "subjectAltName=DNS:${TRUST_MARK_ISSUER_HOST}"
  openssl req -x509 -newkey rsa:4096 -keyout certificates/wallet_provider/privkey.pem -out certificates/wallet_provider/cert+chain.pem -sha256 -days 3650 -nodes --subj "/CN=${WALLET_PROVIDER_HOST}" -addext "subjectAltName=DNS:${WALLET_PROVIDER_HOST}"
fi

hosts=("$TRUST_ANCHOR_HOST" "$TRUST_MARK_ISSUER_HOST" "$WALLET_PROVIDER_HOST" "$FLASK_WALLET_HOST")
unresolvable=()
for host in "${hosts[@]}"; do
    if ! getent hosts "$host" > /dev/null 2>&1; then
        unresolvable+=("$host")
    fi
done

if [ "${#unresolvable[@]}" -gt 0 ]; then
    # Some hosts are unresolvable
    echo "❌ One or more hosts could not be resolved:"
    for host in "${unresolvable[@]}"; do
        echo " - $host"
    done
    
    echo -e "\nTo fix this, add the following entries to your hosts file (e.g., /etc/hosts). Replace '127.0.0.1' with the correct IP addresses, or ideally, add these entries to your DNS:"
    for host in "${unresolvable[@]}"; do
        echo "127.0.0.1 $host"
    done

    echo -e "\nOptions:"
    echo "1. Exit the script and resolve the issue."
    echo "2. Fix issue then continue the script."

    # Prompt user for input
    read -rp "Enter your choice (1/2): " choice
    if [ "$choice" -eq 1 ]; then
        echo "Exiting. Please fix the host resolution issue and rerun the script."
        exit 1
    elif [ "$choice" -ne 2 ]; then
        echo "Invalid choice. Exiting."
        exit 1
    fi
else
    echo "✅ All hosts resolved successfully."
fi

echo "Proceeding with the script..."

if docker network ls | grep -q "$FS_NETWORK_NAME"; then
  echo "Network '$FS_NETWORK_NAME' already exists."
else
  docker network create "$FS_NETWORK_NAME"
  if [ $? -eq 0 ]; then
    echo "Network '$FS_NETWORK_NAME' created successfully."
  else
    echo "Failed to create network '$FS_NETWORK_NAME'."
    exit 1
  fi
fi

# Function to check the running status of a container
check_running_status() {
    local container_id=$1
    local running_status
    running_status=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null || echo "unknown")
    echo "$running_status"
}

# Function to wait for all services to be running
wait_for_services() {
    echo "Waiting for all services to start..."
    for i in $(seq 1 $RETRIES); do
        all_running=true

        for container_id in $(docker compose -f $COMPOSE_FILE ps -q); do
            running_status=$(check_running_status "$container_id")
            if [[ "$running_status" != "running" ]]; then
                echo "$(date): Container $(docker inspect --format='{{.Name}}' "$container_id") is $running_status"
                all_running=false
            fi
        done
        if $all_running; then
            echo "All containers are running."
            break
        fi
        echo "Not all containers are running yet. Retrying in $WAIT_INTERVAL seconds... (Attempt $i of $RETRIES)"
        sleep $WAIT_INTERVAL
    done

    if ! $all_running; then
        echo "Some services did not start within the timeout."
        return 1
    fi

    # Second loop: Ensure webservers are accessible
    echo "Checking service URLs..."
    for j in $(seq 1 $RETRIES); do
        all_urls_reachable=true
        for url in "$TRUST_ANCHOR_WL" "$TRUST_MARK_ISSUER_WL" "$WALLET_PROVIDER_WL" "$FLASK_WALLET_WL"; do
            if ! check_url "$url"; then
                echo "$(date): URL $url is not reachable."
                all_urls_reachable=false
            fi
        done
        if $all_urls_reachable; then
            echo "All services are reachable."
            return 0
        fi
        echo "Some URLs could not be reached. Retrying in $WAIT_INTERVAL seconds... (Attempt $j of $RETRIES)"
        sleep $WAIT_INTERVAL
    done
    return 1
}

# Start services
echo "Starting services using $COMPOSE_FILE..."
docker compose -f $COMPOSE_FILE up -d || {
    echo "Failed to start services. Check the logs for more details."
    exit 1
}

# Wait for services to be running
wait_for_services || {
  echo -e "\nExiting due to unreachable services."
  exit 1
}
echo "Services are up and running:"
docker compose -f $COMPOSE_FILE ps


# Check each URL and print instructions if any are unreachable
echo "Checking URL reachability..."

# Prompt the user for the absolute path to vc_up_and_running
read -p "Enter the absolute path to the vc_up_and_running directory (leave empty if Issuer should not be added to the federation): " VC_UP_AND_RUNNING_PATH
# Verify if the path is provided and exists
if [[ -n "$VC_UP_AND_RUNNING_PATH" ]]; then
  if [[ -d "$VC_UP_AND_RUNNING_PATH" ]]; then
    MOUNT_VC_UP_AND_RUNNING="-v $VC_UP_AND_RUNNING_PATH:/vc_up_and_running"
  else
    echo "Error: The specified Issuer path does not exist. Please check the path and try again."
    exit 1
  fi
else
  echo "No Issuer path provided. Issuer will not be added to the federation."
  MOUNT_VC_UP_AND_RUNNING=""
fi

echo "Using network $FS_NETWORK_NAME"
# Define Docker arguments for the final run command
docker run --rm -i -v $(pwd):/workdir ${MOUNT_VC_UP_AND_RUNNING} -w /workdir --network "$FS_NETWORK_NAME" -e INSIDE_BOOTSTRAP_CONTAINER=true --entrypoint /workdir/"$SCRIPT_NAME" docker.sunet.se/fedservice:latest
docker compose restart
docker compose -f ${VC_UP_AND_RUNNING_PATH}/docker-compose.yaml --project-directory ${VC_UP_AND_RUNNING_PATH} restart 
