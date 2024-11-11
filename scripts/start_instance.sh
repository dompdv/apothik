#!/usr/bin/env bash

APP_NAME="apothik"  # Replace with your application name

# Start the instance
instance_name="${APP_NAME}_$1@127.0.0.1"
elixir --name $instance_name -S mix run --no-halt