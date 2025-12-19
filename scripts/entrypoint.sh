#!/usr/bin/env bash
set -euo pipefail

MAMBA_ROOT_PREFIX=/opt/conda
STORAGE_BASE_DIR="/storage/sd-suite"
STORAGE_COMFYUI_DIR="${STORAGE_BASE_DIR}/comfyui"
STORAGE_JLAB_DIR="${STORAGE_BASE_DIR}/jlab"
JLAB_EXTENSIONS_DIR="${STORAGE_JLAB_DIR}/extensions"
STORAGE_SYSTEM_BASE="${STORAGE_BASE_DIR}/system"
COMFYUI_APP_BASE="/opt/app/ComfyUI"
COMFYUI_CUSTOM_NODES_DIR="${STORAGE_COMFYUI_DIR}/custom_nodes"

# Create directories
mkdir -p "${STORAGE_COMFYUI_DIR}/input" \
 "${STORAGE_COMFYUI_DIR}/output" \
 "${STORAGE_COMFYUI_DIR}/custom_nodes" \
 "${STORAGE_COMFYUI_DIR}/user" \
 "${JLAB_EXTENSIONS_DIR}"

# Install JupyterLab extensions
install_jlab_extensions() {
  micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install /opt/app/jlab_extensions/jupyterlab_comfyui_cockpit-0.1.0-py3-none-any.whl

  shopt -s nullglob
  local extensions=("$JLAB_EXTENSIONS_DIR"/*.whl)
  if [ ${#extensions[@]} -gt 0 ]; then
    echo "Installing JupyterLab extensions: ${extensions[@]}"
    micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install --no-cache-dir "${extensions[@]}"
  else
    echo "No JupyterLab extensions found in ${JLAB_EXTENSIONS_DIR}"
  fi
  shopt -u nullglob
}

install_jlab_extensions

# ----
# Diagnostics: print versions and extension status (helps debug "launcherに出ない")
# ----
echo "=== Jupyter diagnostics (pyenv) ==="
micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv python -V || true
micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv jupyter lab --version || true
echo "--- jupyter server extension list ---"
micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv jupyter server extension list 2>&1 || true
echo "--- jupyter labextension list ---"
micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv jupyter labextension list 2>&1 || true
echo "=== end diagnostics ==="

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
    local node_path="${COMFYUI_CUSTOM_NODES_DIR}/${node}"
    if [ -d "$node_path/.git" ]; then
      echo "Updating pre-installed custom node: $node ..."
      (
        cd "$node_path"

        # Update the node
        git pull --ff-only origin master 2>/dev/null || git pull --ff-only origin main 2>/dev/null || true
      )
    fi
  done
}

install_custom_node_deps_every_start() {
  # Paperspace environments may wipe the Python environment between starts.
  # This installs (Fix相当) requirements for all persisted custom_nodes on every container start.
  local auto="${COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS:-1}"
  if [ "$auto" = "0" ] || [ "$auto" = "false" ]; then
    echo "Skipping custom node deps install (COMFYUI_CUSTOM_NODES_AUTO_INSTALL_DEPS=$auto)"
    return 0
  fi

  if [ ! -d "${COMFYUI_CUSTOM_NODES_DIR}" ]; then
    return 0
  fi

  echo "Ensuring Python deps for custom nodes (every start) ..."
  shopt -s nullglob
  local reqs=("${COMFYUI_CUSTOM_NODES_DIR}"/*/requirements.txt)
  if [ ${#reqs[@]} -eq 0 ]; then
    echo "  → No requirements.txt found under ${COMFYUI_CUSTOM_NODES_DIR}"
    shopt -u nullglob
    return 0
  fi

  for req in "${reqs[@]}"; do
    local node_dir; node_dir="$(dirname "$req")"
    local node_name; node_name="$(basename "$node_dir")"
    echo "  → Installing deps for: ${node_name}"
    (
      cd "$node_dir"
      # Do not fail the whole container if one node has incompatible deps;
      # user can still fix/disable that node from Manager.
      micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv pip install \
        --upgrade-strategy only-if-needed \
        -r "requirements.txt" || true
    )
  done
  shopt -u nullglob
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

for d in input output custom_nodes user; do
  link_dir "${COMFYUI_APP_BASE}/${d}" "${STORAGE_COMFYUI_DIR}/${d}"
done

# Update pre-installed custom nodes after linking
update_preinstalled_nodes

# Install python deps for all custom nodes after linking
install_custom_node_deps_every_start

echo "Starting Supervisor (ComfyUI)..."
# Start supervisord in daemon mode (configured in supervisord.conf)
supervisord -c /etc/supervisord.conf

if [ "$#" -gt 0 ]; then
  # Always run user command inside the managed env so installed extensions match the running Jupyter.
  exec micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv "$@"
else
  exec micromamba run -p ${MAMBA_ROOT_PREFIX}/envs/pyenv \
    jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --ServerApp.token= --ServerApp.password=
fi

