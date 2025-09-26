#!/bin/sh
set -e

READY_FILE="/modpack/.ready-${SERVER_WORLDNAME}"
WORLD_PATH="/data/${SERVER_WORLDNAME}"
GLOBAL_DP="/data/datapacks"
WORLD_DP="${WORLD_PATH}/datapacks"

echo "[wait-for-modpack] Waiting for modpack install for world: $SERVER_WORLDNAME"
while [ ! -f "$READY_FILE" ]; do
  sleep 1
done

echo "[wait-for-modpack] Modpack is ready."

# Wait for world folder to be created by Minecraft
echo "[wait-for-modpack] Waiting for world folder to be created at $WORLD_PATH..."
while [ ! -d "$WORLD_PATH" ]; do
  sleep 2
done

# Copy global datapacks into the world datapacks folder
echo "[wait-for-modpack] Copying datapacks from $GLOBAL_DP to $WORLD_DP..."
mkdir -p "$WORLD_DP"

if [ -d "$GLOBAL_DP" ]; then
  # Copy .zip files and folders
  cp -rv "$GLOBAL_DP"/* "$WORLD_DP/" || echo "⚠️ No datapacks found to copy."
else
  echo "⚠️ Global datapack folder $GLOBAL_DP does not exist."
fi

echo "[wait-for-modpack] Datapacks copied. Starting Minecraft..."
exec /start
