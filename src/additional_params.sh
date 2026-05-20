#!/usr/bin/env bash

# # Define the target directory clearly
# NODE_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-New-Node"

# if [ ! -d "$NODE_DIR" ]; then
#     echo "📥 Installing new node: ComfyUI-New-Node"
#     git clone --depth 1 https://github.com/example/ComfyUI-New-Node.git "$NODE_DIR"
    
#     # Automatically install requirements if they exist
#     if [ -f "$NODE_DIR/requirements.txt" ]; then
#         echo "📦 Installing requirements for ComfyUI-New-Node..."
#         /opt/venv/bin/python3 -m pip install -r "$NODE_DIR/requirements.txt"
#     fi
# else
#     echo "✅ ComfyUI-New-Node already exists. pulling latest updates..."
#     (cd "$NODE_DIR" && git pull --ff-only)
# fi

# # Force update all nodes and install any new missing dependencies
# find "$NETWORK_VOLUME/ComfyUI/custom_nodes" -maxdepth 2 -name "requirements.txt" -exec /opt/venv/bin/python3 -m pip install -r {} \;