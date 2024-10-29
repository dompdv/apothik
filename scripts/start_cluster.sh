#!/usr/bin/env bash

# Number of instances
NUM_INSTANCES=5

LAST_INSTANCE_NUMBER=$((NUM_INSTANCES - 1))
# Application name
APP_NAME="apothik"  # Replace with your application name

# Start an instance of the application
start_instance() {
  local instance_id=$1
  local node_name="${APP_NAME}_${instance_id}@127.0.0.1"

  echo "Starting instance $instance_id with node $node_name..."

  # Start the application using mix run
  # The node name and cookie need to be set for clustering
  # Here, there is no cookie: the standard ~/.erlang.cookie file is automatically
  # used (and generated if there is none)
  elixir --name $node_name -S mix run --no-halt &
}

mix compile

# Start each instance
for i in $(seq 0 $LAST_INSTANCE_NUMBER); do
  start_instance $i
done

wait
