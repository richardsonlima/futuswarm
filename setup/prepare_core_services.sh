#!/usr/bin/env bash
source init.sh

HOST="${HOST:-$(manager_ip)}"


yellow "Building Docker Flow Proxy image..."
DFP_IMAGE="futuswarm/docker-flow-proxy"
rm -rf /tmp/docker-flow-proxy
cp -R ../docker-flow-proxy /tmp/docker-flow-proxy/
# CONFIG_DIR overrides
if [ -d "$CDIR/docker-flow-proxy/" ]; then
    cp -R $CDIR/docker-flow-proxy/* /tmp/docker-flow-proxy/
fi
cd /tmp/docker-flow-proxy
git init . 1>/dev/null
git add -A 1>/dev/null
git commit -m "all in" 1>/dev/null
DFP_TAG="${DFP_TAG:-$(git rev-parse --short HEAD)}"
docker build -t "$DFP_IMAGE:$DFP_TAG" . 1>/dev/null
cd - 1>/dev/null
cd ../client
yellow "Pushing DFP docker image to Swarm..."
( SU=true . ./cli.sh image:push -i "$DFP_IMAGE" -t "$DFP_TAG" )
cd - 1>/dev/null


yellow "Building Docker Flow Proxy (listener) image..."
DFL_IMAGE="futuswarm/docker-flow-swarm-listener"
rm -rf /tmp/docker-flow-swarm-listener
cp -R ../docker-flow-swarm-listener /tmp/docker-flow-swarm-listener/
# CONFIG_DIR overrides
if [ -d "$CDIR/docker-flow-swarm-listener/" ]; then
    cp -R $CDIR/docker-flow-swarm-listener/* /tmp/docker-flow-swarm-listener/
fi
cd /tmp/docker-flow-swarm-listener
git init . 1>/dev/null
git add -A 1>/dev/null
git commit -m "all in" 1>/dev/null
DFL_TAG="${DFL_TAG:-$(git rev-parse --short HEAD)}"
docker build -t "$DFL_IMAGE:$DFL_TAG" . 1>/dev/null
cd - 1>/dev/null
cd ../client
yellow "Pushing DFP:swarm-listener docker image to Swarm..."
( SU=true . ./cli.sh image:push -i "$DFL_IMAGE" -t "$DFL_TAG" )
cd - 1>/dev/null


yellow "Building Single Sign On (sso-proxy) image..."
SSO_IMAGE=futurice/sso-proxy
SSO_NAME=sso-proxy
# defaults
rm -rf /tmp/proxy
cp -R ../proxy /tmp/proxy/
# CONFIG_DIR overrides
if [ -d "$CDIR/proxy/" ]; then
    cp $CDIR/proxy/* /tmp/proxy/
fi
cd /tmp/proxy
git init . 1>/dev/null
git add -A 1>/dev/null
git commit -m "all in" 1>/dev/null
SSO_TAG="${SSO_TAG:-$(git rev-parse --short HEAD)}"
docker build -t "$SSO_IMAGE:$SSO_TAG" . 1>/dev/null
cd - 1>/dev/null
cd ../client
yellow "Pushing SSO-proxy docker image to Swarm..."
( SU=true . ./cli.sh image:push -i "$SSO_IMAGE" -t "$SSO_TAG" )
cd - 1>/dev/null


REMOTE=$(cat <<EOF
docker network create --driver overlay proxy||true
EOF
)
R=$(run_sudo $HOST "$REMOTE")
echo "$R"|grep -v "already exists"

SERVICE_EXISTS="$(does_service_exist $SSO_NAME)"
rg_status "$SERVICE_EXISTS" "'$SSO_NAME' is a Swarm service"
if [[ -n "$SERVICE_EXISTS" ]]; then
yellow " updating '$SSO_NAME' with given tag '$SSO_TAG'"
SSH_ARGS="-t sudo" sudo_client $HOST "docker service update --image $SSO_IMAGE:$SSO_TAG $SSO_NAME --detach"
else
yellow " creating $SSO_NAME service"
FMT_LOG_OPTS="${LOG_OPTS//__NAME__/$SSO_NAME}"
REMOTE=$(cat <<EOF
docker service create \
    --name $SSO_NAME \
    -p 80:80 \
    -p 443:443 \
    --network proxy \
    --constraint 'node.role==manager' \
    --detach \
    $FMT_LOG_OPTS \
    $SSO_IMAGE:$SSO_TAG
EOF
)
SSH_ARGS="-t sudo" sudo_client $HOST "'$REMOTE'"
fi


SERVICE_EXISTS="$(does_service_exist swarm-listener)"
rg_status "$SERVICE_EXISTS" "Docker Flow Proxy: 'swarm-listener' is a Swarm service"
if [[ -n "$SERVICE_EXISTS" ]]; then
yellow " updating Docker Flow Proxy (swarm-listener) service"
REMOTE=$(cat <<EOF
docker service update --image $DFL_IMAGE:$DFL_TAG swarm-listener
EOF
)
SSH_ARGS="-t sudo" sudo_client "$HOST" "'$REMOTE'"
else
yellow " creating Docker Flow Proxy (swarm-listener) service"
FMT_LOG_OPTS="${LOG_OPTS//__NAME__/swarm-listener}"
REMOTE=$(cat <<EOF
docker service create --name swarm-listener \
    --network proxy \
    --mount "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock" \
    -e DF_NOTIFY_CREATE_SERVICE_URL=http://proxy:8080/v1/docker-flow-proxy/reconfigure \
    -e DF_NOTIFY_REMOVE_SERVICE_URL=http://proxy:8080/v1/docker-flow-proxy/remove \
    --constraint 'node.role==manager' \
    --detach \
    $FMT_LOG_OPTS \
    $DFL_IMAGE:$DFL_TAG
EOF
)
SSH_ARGS="-t sudo" sudo_client "$HOST" "'$REMOTE'"
fi

SERVICE_EXISTS="$(does_service_exist proxy)"
rg_status "$SERVICE_EXISTS" "Docker Flow Proxy: 'proxy' is a Swarm service"
if [[ -n "$SERVICE_EXISTS" ]]; then
yellow " updating Docker Flow Proxy (proxy) service"
REMOTE=$(cat <<EOF
docker service update --image $DFP_IMAGE:$DFP_TAG proxy
EOF
)
SSH_ARGS="-t sudo" sudo_client "$HOST" "'$REMOTE'"
else
yellow " creating Docker Flow Proxy (proxy) service"
# Configuration documentation:
# https://proxy.dockerflow.com/config/
FMT_LOG_OPTS="${LOG_OPTS//__NAME__/proxy}"
REMOTE=$(cat <<EOF
docker service create --name proxy \
    -p 81:80 \
    -p 444:443 \
    --network proxy \
    -e MODE=swarm \
    -e LISTENER_ADDRESS=swarm-listener \
    -e SERVICE_DOMAIN_ALGO="hdr_beg(host)" \
    -e CONNECTION_MODE=http-server-close \
    -e DEFAULT_PORTS="81,444:ssl" \
    -e TIMEOUT_HTTP_REQUEST=300 \
    -e TERMINATE_ON_RELOAD=true \
    -e CHECK_RESOLVERS=true \
    -e DEBUG=true \
    -e DEBUG_ERRORS_ONLY=true \
    --constraint 'node.role==manager' \
    --detach \
    $FMT_LOG_OPTS \
    $DFP_IMAGE:$DFP_TAG
EOF
)
SSH_ARGS="-t sudo" sudo_client "$HOST" "'$REMOTE'"
fi


