#!/usr/bin/env bash
set -euo pipefail

MAMBA_ROOT_PREFIX=/opt/conda
NOTEBOOKS_WORKSPACE_BASE="/notebooks/workspace"
STORAGE_SYSTEM_BASE="/storage/system"
FILEBROWSER_SYSTEM_BASE="${STORAGE_SYSTEM_BASE}/filebrowser"
COMFYUI_SYSTEM_BASE="${STORAGE_SYSTEM_BASE}/comfyui"
COMFYUI_APP_BASE="/opt/app/ComfyUI"
mkdir -p "${FILEBROWSER_SYSTEM_BASE}" "${NOTEBOOKS_WORKSPACE_BASE}/input" "${NOTEBOOKS_WORKSPACE_BASE}/output" "${NOTEBOOKS_WORKSPACE_BASE}/custom_nodes" "${NOTEBOOKS_WORKSPACE_BASE}/user"

# Optionally update ComfyUI repo to the latest on container start
# Set COMFYUI_AUTO_UPDATE=0 to disable
update_comfyui() {
  local auto="${COMFYUI_AUTO_UPDATE:-1}"
  if [ "$auto" = "0" ] || [ "$auto" = "false" ]; then
    return 0
  fi
  if [ ! -d "${COMFYUI_APP_BASE}/.git" ]; then
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "WARN: git not available; skipping ComfyUI update" >&2
    return 0
  fi
  echo "Updating ComfyUI in ${COMFYUI_APP_BASE} ..."
  (
    cd "${COMFYUI_APP_BASE}"
    
    # Get latest release tag from GitHub API
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/]+)\.git? ]]; then
      owner="${BASH_REMATCH[1]}"
      repo="${BASH_REMATCH[2]%.git}"
      
      # Try to get latest release tag from GitHub API
      latest_tag=$(curl -sL "https://api.github.com/repos/${owner}/${repo}/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
      
      if [ -n "$latest_tag" ]; then
        echo "  → Checking out latest release: $latest_tag"
        git fetch --tags origin 2>/dev/null || true
        git checkout "$latest_tag" 2>/dev/null || git checkout -b "release-${latest_tag}" "$latest_tag" 2>/dev/null || true
      else
        # Fallback to branch update if no release found
        echo "  → No release found, updating from branch..."
        git pull --ff-only origin master 2>/dev/null || git pull --ff-only origin main 2>/dev/null || true
      fi
    else
      # Fallback for non-GitHub repositories
      git pull --ff-only origin master 2>/dev/null || git pull --ff-only origin main 2>/dev/null || true
    fi
    
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install -r /opt/app/ComfyUI/requirements.txt
  )
}

update_comfyui

# Update pre-installed custom nodes
update_preinstalled_nodes() {
  local auto="${COMFYUI_CUSTOM_NODES_AUTO_UPDATE:-1}"
  if [ "$auto" = "0" ] || [ "$auto" = "false" ]; then
    return 0
  fi
  
  local nodes=(
    "ComfyUI-Manager"
    "nunchaku_nodes"
    "ComfyUI-ProxyFix"
  )
  
  for node in "${nodes[@]}"; do
    local node_path="${NOTEBOOKS_WORKSPACE_BASE}/custom_nodes/${node}"
    if [ -d "$node_path/.git" ]; then
      echo "Updating pre-installed custom node: $node ..."
      (
        cd "$node_path"
        
        # Marker file to track if dependencies were installed
        local deps_marker=".deps_installed"
        local is_first_run=false
        if [ ! -f "$deps_marker" ]; then
          is_first_run=true
        fi
        
        # Hash requirements.txt before update (if exists)
        local req_hash_before=""
        if [ -f "requirements.txt" ]; then
          req_hash_before=$(md5sum requirements.txt 2>/dev/null | cut -d' ' -f1)
        fi
        
        # Update the node
        git pull --ff-only origin master 2>/dev/null || git pull --ff-only origin main 2>/dev/null || true
        
        # Check if requirements.txt changed or is new
        local needs_install=false
        if [ -f "requirements.txt" ]; then
          local req_hash_after=$(md5sum requirements.txt 2>/dev/null | cut -d' ' -f1)
          if [ "$is_first_run" = true ]; then
            needs_install=true
            echo "  → First run, ensuring dependencies are installed..."
          elif [ "$req_hash_before" != "$req_hash_after" ]; then
            needs_install=true
            echo "  → requirements.txt changed, installing dependencies..."
          fi
        fi
        
        # Install dependencies only if needed
        if [ "$needs_install" = true ]; then
          micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install --upgrade-strategy only-if-needed -r requirements.txt
          touch "$deps_marker"
        fi
      )
    fi
  done
}

link_dir() {
  local src="$1"; local dst="$2";
  if [ -L "$src" ]; then return 0; fi
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null || true)" ]; then
    echo "Migrating existing data from $src to $dst ..."
    mkdir -p "$dst"
    # -n: do not overwrite existing files (no-clobber)
    # This preserves user-added custom_nodes while adding pre-installed ones on first run
    cp -an "$src"/. "$dst"/ 2>/dev/null || true
    rm -rf "$src"
  fi
  ln -sfn "$dst" "$src"
}

link_dir "${COMFYUI_APP_BASE}/input" "${NOTEBOOKS_WORKSPACE_BASE}/input"
link_dir "${COMFYUI_APP_BASE}/output" "${NOTEBOOKS_WORKSPACE_BASE}/output"
link_dir "${COMFYUI_APP_BASE}/custom_nodes" "${NOTEBOOKS_WORKSPACE_BASE}/custom_nodes"
link_dir "${COMFYUI_APP_BASE}/user" "${NOTEBOOKS_WORKSPACE_BASE}/user"

# Update pre-installed custom nodes after linking
update_preinstalled_nodes

FB_DB="${FILEBROWSER_SYSTEM_BASE}/filebrowser.db"
if [ ! -f "$FB_DB" ]; then
  # Initialize database on first run
  filebrowser -d "$FB_DB" config init
fi
# Enforce noauth every startup
filebrowser -d "$FB_DB" config set --auth.method noauth

echo "Starting ComfyUI service..."
cd "${COMFYUI_APP_BASE}"
nohup python main.py --listen 127.0.0.1 --port 8189 > /tmp/comfyui.log 2>&1 &
COMFYUI_PID=$!
cd /notebooks
echo "ComfyUI started with PID: $COMFYUI_PID (port 8189)"

# Start Filebrowser service in background
echo "Starting Filebrowser service..."
nohup filebrowser --address 127.0.0.1 --port 8766 --root "${NOTEBOOKS_WORKSPACE_BASE}" --database "${FB_DB}" --baseurl /filebrowser > /tmp/filebrowser.log 2>&1 &
FILEBROWSER_PID=$!
echo "Filebrowser started with PID: $FILEBROWSER_PID (port 8766)"

# Start Studio service in background
echo "Starting Studio service..."
nohup studio --port 8765 --base-url /studio > /tmp/studio.log 2>&1 &
STUDIO_PID=$!
echo "Studio started with PID: $STUDIO_PID (port 8765)"

if [ "$#" -gt 0 ]; then
  exec "$@"
else
  exec jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --ServerApp.token= --ServerApp.password=
fi
