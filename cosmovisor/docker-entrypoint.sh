#!/usr/bin/env bash
set -euo pipefail

# This is specific to each chain.
__daemon_download_url=https://github.com/zeta-chain/node/releases/download/$DAEMON_VERSION/zetacored-linux-amd64

# Common cosmovisor paths.
__cosmovisor_path=/cosmos/cosmovisor
__genesis_path=$__cosmovisor_path/genesis
__current_path=$__cosmovisor_path/current
__upgrades_path=$__cosmovisor_path/upgrades

if [[ ! -f /cosmos/.initialized ]]; then
  echo "Initializing..."
  wget $__daemon_download_url -O $__genesis_path/bin/$DAEMON_NAME
  chmod a+x $__genesis_path/bin/$DAEMON_NAME

  # Point to current.
  ln -s -f $__genesis_path $__current_path

  if [[ "$NETWORK" == "mainnet" ]]; then
    __config_base_url="https://raw.githubusercontent.com/zeta-chain/network-config/refs/heads/main/mainnet"
    __chain_id="zetachain_7000-1"
  elif [[ "$NETWORK" == "testnet" ]]; then
    __config_base_url="https://raw.githubusercontent.com/zeta-chain/network-config/refs/heads/main/athens3"
    __chain_id="athens_7001-1"
  else
    echo "Unknown network"
    exit 1
  fi

  echo "Running init..."
  $__genesis_path/bin/$DAEMON_NAME init $MONIKER --chain-id $__chain_id --home /cosmos --overwrite

  echo "Downloading config..."
  wget $__config_base_url/genesis.json -O /cosmos/config/genesis.json
  wget $__config_base_url/client.toml -O /cosmos/config/client.toml
  wget $__config_base_url/config.toml -O /cosmos/config/config.toml
  wget $__config_base_url/app.toml -O /cosmos/config/app.toml

  if [ -n "$SNAPSHOT" ]; then
    echo "Downloading snapshot..."
    curl -o - -L $SNAPSHOT | lz4 -c -d - | tar -x -C /cosmos
  else
    echo "No snapshot URL defined, will attempt to sync from scratch."
  fi

  touch /cosmos/.initialized
else
  echo "Already initialized!"
fi

# Handle updates and upgrades.
__should_update=0

compare_versions() {
    current=$1
    new=$2

    # Extract major, minor, and patch versions
    major_current=$(echo "$current" | cut -d. -f1 | sed 's/v//')
    major_new=$(echo "$new" | cut -d. -f1 | sed 's/v//')

    minor_current=$(echo "$current" | cut -d. -f2)
    minor_new=$(echo "$new" | cut -d. -f2)

    patch_current=$(echo "$current" | cut -d. -f3)
    patch_new=$(echo "$new" | cut -d. -f3)

    # Compare major versions
    if [ "$major_current" -lt "$major_new" ]; then
        __should_update=2
        return
    elif [ "$major_current" -gt "$major_new" ]; then
        __should_update=0
        return
    fi

    # Compare minor versions
    if [ "$minor_current" -lt "$minor_new" ]; then
        __should_update=2
        return
    elif [ "$minor_current" -gt "$minor_new" ]; then
        __should_update=0
        return
    fi

    # Compare patch versions
    if [ "$patch_current" -lt "$patch_new" ]; then
        __should_update=1
        return
    elif [ "$patch_current" -gt "$patch_new" ]; then
        __should_update=0
        return
    fi

    # Versions are the same
    __should_update=0
}

# Upgrades overview.

# Protocol Upgrades:
# - In-protocol signaling for the upgrade.
# - These involve significant changes to the network, such as major or minor version releases.
# - Stored in a dedicated directory: /cosmos/cosmovisor/{upgrade_name}.
# - Cosmovisor automatically manages the switch based on the network's upgrade plan.

# Binary Updates:
# - These are smaller, incremental changes such as patch-level fixes.
# - Only the binary is replaced in the existing /cosmos/cosmovisor/{upgrade_name} directory.
# - Binary updates are applied immediately without additional actions.

# First, we get the current version and compare it with the desired version.
__current_version=$($__current_path/bin/$DAEMON_NAME version)
compare_versions $__current_version $DAEMON_VERSION

echo "Current version: ${__current_version}. Desired version: ${DAEMON_VERSION}"

# __should_update=0: No update needed or versions are the same.
# __should_update=1: Higher patch version.
# __should_update=2: Higher minor or major version.
if [ "$__should_update" -eq 2 ]; then
  echo "Downloading network upgrade..."
  # This is a network upgrade. We'll download the binary, put it in a new folder
  # and we'll let cosmovisor handle the upgrade just in time.
  __proposals_url="${ARCHIVE_RPC_URL}/cosmos/gov/v1/proposals?pagination.reverse=true&proposal_status=PROPOSAL_STATUS_PASSED&pagination.limit=100"
  __proposal=$(curl -s "$__proposals_url" | jq -r --arg version "$DAEMON_VERSION" '
    .proposals[] |
    select(.status == "PROPOSAL_STATUS_PASSED" and (.metadata | contains($DAEMON_VERSION)))
  ')
  __upgrade_name=$(echo "$__proposal" | jq -r '.messages[0].plan.name')

  mkdir -p $__cosmovisor_path/$__upgrade_name/bin
  wget $__daemon_download_url -O $__upgrades_path/$__upgrade_name/bin/$DAEMON_NAME
  echo "Done!"
elif [ "$__should_update" -eq 1 ]; then
  echo "Updating binary for current version."
  wget $__daemon_download_url -O $__current_path/bin/$DAEMON_NAME
  echo "Done!"
else
  echo "No updates needed."
fi

echo "Updating config..."

# Get public IP address.
__public_ip=$(curl -s ifconfig.me/ip)
echo "Public ip: ${__public_ip}"

# Always update public IP address, moniker and ports.
dasel put -f /cosmos/config/config.toml -v "${__public_ip}:${CL_P2P_PORT}" p2p.external_address
dasel put -f /cosmos/config/config.toml -v "tcp://0.0.0.0:${CL_P2P_PORT}" p2p.laddr
dasel put -f /cosmos/config/config.toml -v "tcp://0.0.0.0:${CL_RPC_PORT}" rpc.laddr
dasel put -f /cosmos/config/config.toml -v ${MONIKER} moniker
dasel put -f /cosmos/config/config.toml -v true prometheus
dasel put -f /cosmos/config/config.toml -v ${LOG_LEVEL} log_level
dasel put -f /cosmos/config/app.toml -v "0.0.0.0:${RPC_PORT}" json-rpc.address
dasel put -f /cosmos/config/app.toml -v "0.0.0.0:${WS_PORT}" json-rpc.ws-address
dasel put -f /cosmos/config/client.toml -v "tcp://localhost:${CL_RPC_PORT}" node

# cosmovisor will create a subprocess to handle upgrades
# so we need a special way to handle SIGTERM

# Start the process in a new session, so it gets its own process group.
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
setsid "$@" ${EXTRA_FLAGS} &
pid=$!

# Trap SIGTERM in the script and forward it to the process group
trap 'kill -TERM -$pid' TERM

# Wait for the background process to complete
wait $pid
