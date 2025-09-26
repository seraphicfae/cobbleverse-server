#!/bin/sh
set -e

# ------------------------------------------------------------------------------
# install-modpack.sh
# Installs a Modrinth .mrpack into /modpack, unpacks server-side bits into
# /data, and marks the install as complete for this world.
# ------------------------------------------------------------------------------

apk add --no-cache jq wget unzip rsync > /dev/null

# Paths and defaults
MODPACK_DIR=/modpack
TEMP_DIR="$MODPACK_DIR/temp"
MRPACK_PATH="$MODPACK_DIR/pack.mrpack"
READY_FILE="$MODPACK_DIR/.ready-${SERVER_WORLDNAME}"
DATA_DIR=/data

MC_UID=${MC_UID:-1000}
MC_GID=${MC_GID:-1000}

# ------------------------------------------------------------------------------
# Skip if already installed for this world
# ------------------------------------------------------------------------------
if [ -f "$READY_FILE" ]; then
  echo "✅ Modpack already installed for world: $SERVER_WORLDNAME"
  exit 0
fi

cd "$MODPACK_DIR"

echo "🧹 Cleaning previous temp / mods folders…"
rm -rf "$TEMP_DIR" "$MODPACK_DIR/mods"
mkdir -p "$TEMP_DIR" "$MODPACK_DIR/mods"

echo "⬇️  Downloading modpack from $MODRINTH_URL…"
wget -q -O "$MRPACK_PATH" "$MODRINTH_URL"

if [ ! -s "$MRPACK_PATH" ]; then
  echo "❌ ERROR: Downloaded .mrpack is empty or missing!"
  exit 1
fi

echo "📦 Extracting .mrpack…"
unzip -q "$MRPACK_PATH" -d "$TEMP_DIR"

INDEX_JSON="$TEMP_DIR/modrinth.index.json"
[ ! -f "$INDEX_JSON" ] && INDEX_JSON="$TEMP_DIR/index.json"

if [ ! -f "$INDEX_JSON" ]; then
  echo "❌ ERROR: No index file (modrinth.index.json or index.json) found!"
  exit 1
fi

echo "📖 Using index file: $(basename "$INDEX_JSON")"
echo "🔗 Downloading server-side mods…"

CLIENT_ONLY_MODS="cobblemon-ui-tweaks|interactic|ferritecore"

jq -c '.files[] | select(.env.server == "required")' "$INDEX_JSON" | while read -r entry; do
  FILE_PATH=$(echo "$entry" | jq -r '.path')

  if echo "$FILE_PATH" | grep -Eiq "$CLIENT_ONLY_MODS"; then
    echo "🚫 Skipping client-only mod: $FILE_PATH"
    continue
  fi

  FILE_URL=$(echo "$entry" | jq -r '.downloads[0]')
  DEST_PATH="$MODPACK_DIR/$FILE_PATH"

  if [ -n "$FILE_URL" ]; then
    echo "   • $FILE_PATH"
    mkdir -p "$(dirname "$DEST_PATH")"
    wget -q -O "$DEST_PATH" "$FILE_URL"
  else
    echo "⚠️  No URL found for $FILE_PATH – skipped"
  fi
done

echo "✅ Finished downloading mods."

# ------------------------------------------------------------------------------
# Copy override folders
# ------------------------------------------------------------------------------
copy_override() {
  local SRC="$1" DST="$2" LABEL="$3"
  if [ -d "$SRC" ]; then
    echo "📁 Copying $LABEL override…"
    rsync -a "$SRC/" "$DST/"
  fi
}

copy_override "$TEMP_DIR/overrides/config"        "$MODPACK_DIR/config"        "config"
copy_override "$TEMP_DIR/overrides/resourcepacks" "$MODPACK_DIR/resourcepacks" "resourcepacks"

# Flatten datapacks
if [ -d "$TEMP_DIR/overrides/datapacks" ]; then
  echo "📁 Copying datapacks override (flattened)…"
  mkdir -p "$MODPACK_DIR/datapacks"
  rsync -a "$TEMP_DIR/overrides/datapacks/" "$MODPACK_DIR/datapacks/"
fi

flatten_dp() {
  local TARGET="$1"
  if [ -d "$TARGET/datapacks" ]; then
    echo "⚙️  Flattening nested datapacks in $TARGET"
    rsync -a "$TARGET/datapacks/" "$TARGET/"
    rm -rf "$TARGET/datapacks"
  fi
}

flatten_dp "$MODPACK_DIR"
find "$MODPACK_DIR/datapacks" -name '.DS_Store' -delete 2>/dev/null || true

# ------------------------------------------------------------------------------
# Move content into /data (live server directory)
# ------------------------------------------------------------------------------
echo "🚚 Copying mods into live server dir…"
mkdir -p "$DATA_DIR/mods"
rm -rf "$DATA_DIR/mods"/*
rsync -a "$MODPACK_DIR/mods/" "$DATA_DIR/mods/"

echo "🚚 Copying configs…"
mkdir -p "$DATA_DIR/config"
rsync -a --ignore-existing "$MODPACK_DIR/config/" "$DATA_DIR/config/" 2>/dev/null || true

echo "🚚 Copying global datapacks..."
mkdir -p "$DATA_DIR/datapacks"
DATAPACKS_FOUND=false

# Copy .zip datapacks
for ZIP in "$MODPACK_DIR"/*.zip; do
  if [ -f "$ZIP" ]; then
    echo "📦 Copying datapack: $(basename "$ZIP")"
    cp -v "$ZIP" "$DATA_DIR/datapacks/"
    DATAPACKS_FOUND=true
  fi
done

# Copy "extra/" folder (if it exists)
if [ -d "$MODPACK_DIR/extra" ]; then
  echo "📁 Copying 'extra/' datapack folder"
  rsync -a "$MODPACK_DIR/extra/" "$DATA_DIR/datapacks/extra/"
  DATAPACKS_FOUND=true
fi

if [ "$DATAPACKS_FOUND" = false ]; then
  echo "⚠️ No datapacks found (.zip or extra folder) in $MODPACK_DIR"
fi

# Clean and flatten
flatten_dp "$DATA_DIR/datapacks"
find "$DATA_DIR/datapacks" -name '.DS_Store' -delete 2>/dev/null || true

echo "🚚 Copying per-world datapacks…"
WORLD_DP="$DATA_DIR/${SERVER_WORLDNAME}/datapacks"
mkdir -p "$WORLD_DP"

echo "📦 Copying global datapacks into world: $WORLD_DP"
rsync -a "$DATA_DIR/datapacks/" "$WORLD_DP/"

flatten_dp "$WORLD_DP"
find "$WORLD_DP" -name '.DS_Store' -delete 2>/dev/null || true


# ------------------------------------------------------------------------------
# Permissions
# ------------------------------------------------------------------------------
echo "🔒 Fixing permissions to ${MC_UID}:${MC_GID} …"
chown -R "${MC_UID}:${MC_GID}" /data /modpack
chmod -R u+rwX,go+rX /data /modpack

# ------------------------------------------------------------------------------
# Optional: Tree snapshot
# ------------------------------------------------------------------------------
if command -v tree >/dev/null 2>&1; then
  tree -a -F > "$MODPACK_DIR/file_structure.txt"
  tree -a --dirsfirst -L 4 > "$MODPACK_DIR/folder_tree.txt"
fi

echo "🎉 Modpack install complete for world: $SERVER_WORLDNAME – $(find "$MODPACK_DIR/mods" -name '*.jar' | wc -l) mod jars ready."

# ------------------------------------------------------------------------------
# Set Cobblemon debug setting (only if config file exists)
# ------------------------------------------------------------------------------
CFG="/data/config/cobblemon/main.json"
if [ -f "$CFG" ]; then
  echo "🔧 Enabling exportSpawnConfig=true in Cobblemon config…"
  TMP=$(mktemp)
  jq '.exportSpawnConfig = true' "$CFG" > "$TMP" && mv "$TMP" "$CFG"
else
  echo "⚠️ Cobblemon config not found at $CFG — skipping spawn config tweak."
fi

# ------------------------------------------------------------------------------
# Mark as installed
# ------------------------------------------------------------------------------
touch "$READY_FILE"
