#!/usr/bin/env bash
cat << 'EOF' > /usr/local/bin/comfyui-sync
#!/usr/bin/env bash

# 1. Environment & Path Resolutions
PYTHON_BIN="/usr/bin/python3"
NETWORK_VOLUME="${NETWORK_VOLUME:-/workspace}"
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"
COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
LOG_FILE="$NETWORK_VOLUME/comfyui_nohup.log"

echo "🔄 Initializing On-Demand Dependency Sync engine..."
echo "📂 Scanning custom nodes directory..."

if [ ! -d "$CUSTOM_NODES_DIR" ]; then
    echo "❌ Error: Custom nodes directory not found at $CUSTOM_NODES_DIR"
    exit 1
fi

updated_nodes=0
patched_dependencies=0

# 2. Synchronize Code and Apply Environment Shields
while read -r node_path; do
    if [ -d "$node_path/.git" ] || [ -f "$node_path/requirements.txt" ]; then
        node_name=$(basename "$node_path")
        REQ_FILE="$node_path/requirements.txt"
        CUPY_FILE="$node_path/requirements-with-cupy.txt"
        
        BEFORE_MOD=0
        CUPY_BEFORE=0
        [ -f "$REQ_FILE" ] && BEFORE_MOD=$(stat -c %Y "$REQ_FILE" 2> /dev/null || stat -f %m "$REQ_FILE" 2> /dev/null)
        [ -f "$CUPY_FILE" ] && CUPY_BEFORE=$(stat -c %Y "$CUPY_FILE" 2> /dev/null || stat -f %m "$CUPY_FILE" 2> /dev/null)

        # Catch upstream updates if git tracking is active
        if [ -d "$node_path/.git" ]; then
            (cd "$node_path" && git reset --hard HEAD -q && git pull --ff-only -q) > /dev/null 2>&1
        fi

        AFTER_MOD=0
        CUPY_AFTER=0
        [ -f "$REQ_FILE" ] && AFTER_MOD=$(stat -c %Y "$REQ_FILE" 2> /dev/null || stat -f %m "$REQ_FILE" 2> /dev/null)
        [ -f "$CUPY_FILE" ] && CUPY_AFTER=$(stat -c %Y "$CUPY_FILE" 2> /dev/null || stat -f %m "$CUPY_FILE" 2> /dev/null)
        
        # Trigger if file changed OR if node doesn't have our custom .patched registration marker
        if [ "$BEFORE_MOD" != "$AFTER_MOD" ] || [ "$CUPY_BEFORE" != "$CUPY_AFTER" ] || [ ! -f "$node_path/.patched" ]; then
            
            # Ensure at least one requirements file exists before processing
            if [ -f "$REQ_FILE" ] || [ -f "$CUPY_FILE" ]; then
                echo "📦 Dependencies out of sync for [$node_name]. Applying sanitization shields..."
                ((patched_dependencies++))

                # 🛡️ NODE-SPECIFIC PATCHES (ComfyUI-Frame-Interpolation)
                if [ "$node_name" = "ComfyUI-Frame-Interpolation" ] && [ -f "$CUPY_FILE" ]; then
                    sed -i -E 's/opencv-(python|contrib-python)(-headless)?(\[[a-zA-Z0-9_-]+\])?(==[0-9.]+)?/opencv-contrib-python-headless/g' "$CUPY_FILE"
                    sed -i -E 's/^torch([>=<~= ]+[0-9.]+)?$/# torch already installed/g' "$CUPY_FILE"
                    sed -i -E 's/^torchvision([>=<~= ]+[0-9.]+)?$/# torchvision already installed/g' "$CUPY_FILE"
                    sed -i -E 's/^numpy([>=<~= ]+[0-9.]+)?$/# numpy already installed/g' "$CUPY_FILE"
                    sed -i -E 's/^[Pp]illow([>=<~= ]+[0-9.]+)?$/# Pillow already installed/g' "$CUPY_FILE"
                    sed -i -E 's/^cupy-wheel$/cupy-cuda12x/g' "$CUPY_FILE"
                fi

                # 🛡️ RE-APPLY SYSTEM INTEGRITY SHIELDS (Including Transformers & Insightface)
                if [ -f "$REQ_FILE" ]; then
                    sed -i -E 's/^[Pp]illow([>=<~= ]+[0-9.]+)?$/# Pillow already installed/g' "$REQ_FILE"
                    sed -i -E 's/opencv-(python|contrib-python)(-headless)?(\[[a-zA-Z0-9_-]+\])?(==[0-9.]+)?/opencv-contrib-python-headless/g' "$REQ_FILE"
                    sed -i -E 's/bitsandbytes([>=<~= ]+[0-9.]+)?/bitsandbytes/g' "$REQ_FILE"
                    sed -i -E 's/^protobuf[>=<~=,. 0-9]+$/protobuf/g' "$REQ_FILE"
                    sed -i -E 's/^onnxruntime(-gpu)?([>=<~=,. 0-9]+)?$/onnxruntime-gpu/g' "$REQ_FILE"
                    sed -i -E 's/^torch([>=<~= ]+[0-9.]+)?$/# torch already installed/g' "$REQ_FILE"
                    sed -i -E 's/^torchvision([>=<~= ]+[0-9.]+)?$/# torchvision already installed/g' "$REQ_FILE"
                    sed -i -E 's/^torchaudio([>=<~= ]+[0-9.]+)?$/# torchaudio already installed/g' "$REQ_FILE"
                    sed -i -E 's/^numpy([>=<~= ]+[0-9.]+)?$/# numpy already installed/g' "$REQ_FILE"
                    sed -i -E 's/^numba([>=<~= ]+[0-9.]+)?$/numba/g' "$REQ_FILE"
                    sed -i -E 's/^ninja([>=<~=~ ]+[0-9.]+)?$/ninja/g' "$REQ_FILE"
                    sed -i -E 's/^clip[-_]interrogator([>=<~= ]+[0-9.]+)?$/clip-interrogator/g' "$REQ_FILE"
                    sed -i -E 's/^transformers(\[[a-zA-Z0-9_,]+\])?([>=<~= ]+[0-9.]+)?$/transformers/g' "$REQ_FILE"
                    sed -i -E 's/^insightface([>=<~= ]+[0-9.]+)?$/insightface==1.0.1/g' "$REQ_FILE"
                    sed -i -E 's/^diffusers([>=<~= ]+[0-9.]+)?$/# diffusers already installed/g' "$REQ_FILE"
                    sed -i -E 's/^huggingface-hub([>=<~= ]+[0-9.]+)?$/# huggingface-hub already installed/g' "$REQ_FILE"
                    sed -i -E 's/^(segment-anything|transparent-background)([>=<~= ]+[0-9.]+)?$/# segmentation tooling already installed/g' "$REQ_FILE"
                fi

                # Compile and register packages
                echo "📥 Compiling backend packages for $node_name..."
                
                INSTALL_SUCCESS=true

                if [ -f "$REQ_FILE" ]; then
                    if $PYTHON_BIN -m pip install --no-cache-dir -r "$REQ_FILE" >> "$LOG_FILE" 2>&1; then
                        echo "   ✅ Dependencies installed for $node_name"
                    else
                        echo "   ❌ Dependency install failed for $node_name — check $LOG_FILE"
                        INSTALL_SUCCESS=false
                    fi
                fi

                if [ "$node_name" = "ComfyUI-Frame-Interpolation" ] && [ -f "$CUPY_FILE" ]; then
                    if $PYTHON_BIN -m pip install --no-cache-dir -r "$CUPY_FILE" >> "$LOG_FILE" 2>&1; then
                        echo "   ✅ Cupy dependencies installed for $node_name"
                    else
                        echo "   ❌ Cupy dependency install failed for $node_name — check $LOG_FILE"
                        INSTALL_SUCCESS=false
                    fi
                fi

                if [ "$INSTALL_SUCCESS" = true ]; then
                    touch "$node_path/.patched"
                fi
            fi
        fi
        ((updated_nodes++))
    fi
done < <(find "$CUSTOM_NODES_DIR" -maxdepth 1 -type d -not -path "$CUSTOM_NODES_DIR")

echo "✅ Sync complete. Checked $updated_nodes nodes ($patched_dependencies required env patches)."
echo "----------------------------------------------------------"

# 3. Graceful Process Termination (The Kill Sequence)
echo "🛑 Stopping active ComfyUI backend process..."
kill $(cat /tmp/comfyui.pid 2>/dev/null) 2>/dev/null
sleep 2

# 4. Live Environment Re-Evaluation
GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
VRAM_THRESHOLD=32000

BASE_FLAGS="--listen --preview-method auto"

if [ "${USE_FP8_TEXT_ENC:-true}" = "true" ]; then
    BASE_FLAGS="$BASE_FLAGS --fp8_e4m3fn-text-enc"
fi
if [ "${USE_FP8_MODEL:-}" = "true" ]; then
    BASE_FLAGS="$BASE_FLAGS --fp8_e4m3fn-unet"
fi
if [ "$GPU_VRAM_MB" -ge "$VRAM_THRESHOLD" ]; then
    BASE_FLAGS="$BASE_FLAGS --highvram"
fi
if /usr/bin/python3 -c "import sageattention" &> /dev/null; then
    BASE_FLAGS="$BASE_FLAGS --use-sage-attention"
fi

# 5. Application Launch Phase
echo "📋 Active boot configuration: $BASE_FLAGS"
if [ ! -z "$*" ]; then
    echo "🔧 Appending troubleshooting arguments: $*"
fi

cd "$COMFYUI_DIR" || exit 1
nohup $PYTHON_BIN ./main.py $BASE_FLAGS $* > "$LOG_FILE" 2>&1 &

echo $! > /tmp/comfyui.pid
echo "🚀 ComfyUI hot-swapped successfully! Running on PID $(cat /tmp/comfyui.pid)"
echo "=========================================================="
EOF

chmod +x /usr/local/bin/comfyui-sync
