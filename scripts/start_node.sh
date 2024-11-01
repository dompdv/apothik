#!/usr/bin/env bash
APP_NAME="apothik"
node_name="${APP_NAME}_$1@127.0.0.1"
echo "Starting instance $instance_id with node $node_name..."
elixir --name $node_name -S mix run --no-halt
