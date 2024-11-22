#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /cosmos/.initialized ]]; then
  echo "Initializing..."
  wget https://github.com/zeta-chain/node/releases/download/$ZETACORED_VERSION/zetacored-linux-amd64 -O /cosmos/cosmovisor/genesis/bin/zetacored
  chmod a+x /cosmos/cosmovisor/genesis/bin/zetacored
  /cosmos/cosmovisor/genesis/bin/zetacored version
  ln -s /cosmos/cosmovisor/genesis /cosmos/cosmovisor/current

  if [[ "$NETWORK" == "mainnet" ]]; then
    __config_base_url="https://github.com/zeta-chain/network-config/tree/main/mainnet"
    __chain_id="zetachain_7000-1"
  elif [[ "$NETWORK" == "testnet" ]]; then
    __config_base_url="https://github.com/zeta-chain/network-config/tree/main/athens3"
    __chain_id="athens_7001-1"
  else
    echo "Unknown network"
    exit 1
  fi

  /cosmos/cosmovisor/genesis/bin/zetacored init $MONIKER --chain-id $__chain_id --home /cosmos --overwrite

  echo "Downloading config..."
  wget https://raw.githubusercontent.com/zeta-chain/network-config/main/mainnet/genesis.json -O /cosmos/config/genesis.json
  wget https://raw.githubusercontent.com/zeta-chain/network-config/main/mainnet/client.toml -O /cosmos/config/client.toml
  wget https://raw.githubusercontent.com/zeta-chain/network-config/main/mainnet/config.toml -O /cosmos/config/config.toml
  wget https://raw.githubusercontent.com/zeta-chain/network-config/main/mainnet/app.toml -O /cosmos/config/app.toml

  echo "Downloading snapshot..."
  curl -o - -L $SNAPSHOT_URL | lz4 -c -d - | tar -x -C /cosmos

  touch /cosmos/.initialized
else
  echo "Already initialized!"
fi

echo "Updating config..."
# Always update public IP address and Moniker.
__public_ip=$(curl -s ifconfig.me/ip)
dasel put -f /cosmos/config/config.toml -v "${__public_ip}:${P2P_PORT}" p2p.external_address
dasel put -f /cosmos/config/config.toml -v ${MONIKER} moniker
dasel put -f /cosmos/config/config.toml -v true prometheus
dasel put -f /cosmos/config/config.toml -v ${LOG_LEVEL} log_level

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
