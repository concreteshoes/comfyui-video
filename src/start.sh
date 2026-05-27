#!/usr/bin/env bash

# Function to check if a directory exists and is writable
can_write_to() {
    local target="$1"
    [ -z "$target" ] && return 1

    if [ -d "$target" ]; then
        touch "$target/.write_test" 2> /dev/null || return 1
        rm -f "$target/.write_test"
    else
        mkdir -p "$target" 2> /dev/null || return 1
        touch "$target/.write_test" 2> /dev/null || return 1
        rm -f "$target/.write_test"
    fi

    return 0
}

# Determine NETWORK_VOLUME
if [ -n "${NETWORK_VOLUME-}" ] && can_write_to "$NETWORK_VOLUME"; then
    echo "Using provided NETWORK_VOLUME: $NETWORK_VOLUME"

elif can_write_to "/workspace"; then
    NETWORK_VOLUME="/workspace"
    echo "Defaulting to /workspace"

elif can_write_to "/runpod-volume"; then
    NETWORK_VOLUME="/runpod-volume"
    echo "Defaulting to /runpod-volume"

else
    NETWORK_VOLUME="$(pwd)"
    echo "Fallback to current dir: $NETWORK_VOLUME"
fi

mkdir -p "$NETWORK_VOLUME"
export NETWORK_VOLUME
sed -i '/^export NETWORK_VOLUME=/d' /etc/profile.d/container_env.sh
echo "export NETWORK_VOLUME=\"$NETWORK_VOLUME\"" >> /etc/profile.d/container_env.sh

mkdir -p "$NETWORK_VOLUME/logs"
STARTUP_LOG="$NETWORK_VOLUME/logs/startup.log"
echo "--- Startup log $(date) ---" >> "$STARTUP_LOG"

# Explicitly set the python path
PYTHON_BIN="/usr/bin/python3"

# Keep-alive loop to prevent connection timeout and monitor DNS
(
    echo "Starting network keep-alive service..."
    while true; do
        # Re-enforce DNS just in case the host overrode it
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
        TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

        # 1. Try to ping Google Drive's API endpoint
        if curl -Is --connect-timeout 5 https://www.google.com > /dev/null 2>&1; then
            echo "[$TIMESTAMP] Internet: REACHABLE (HTTPS)"
        else
            echo "[$TIMESTAMP] Internet: UNREACHABLE"
            # Fallback to check raw DNS resolution via a simple tool like 'host' or 'nslookup'
            if nslookup google.com > /dev/null 2>&1; then
                echo "[$TIMESTAMP] Alert: DNS works, but HTTPS traffic is failing."
            else
                echo "[$TIMESTAMP] Alert: Total network/DNS failure."
            fi
        fi

        # Wait 15 minutes (900 seconds)
        sleep 900
    done
) > "$NETWORK_VOLUME/logs/network_keepalive.log" 2>&1 &

# Run a command quietly, logging output to STARTUP_LOG.
# Shows "Still working..." every 10 seconds.
# On failure, prints a warning with the log path.
run_quiet() {
    local label="$1"
    shift

    # 1. Log a header so you know which command is starting
    echo "====================================================" >> "$STARTUP_LOG"
    echo "BEGIN: $label ($(date))" >> "$STARTUP_LOG"
    echo "COMMAND: $*" >> "$STARTUP_LOG"
    echo "====================================================" >> "$STARTUP_LOG"

    (
        while true; do
            sleep 10
            echo "       Still working on $label..."
        done
    ) &
    local heartbeat_pid=$!

    # 2. Run command. Adding --progress-bar off for pip specifically
    "$@" >> "$STARTUP_LOG" 2>&1
    local exit_code=$?

    kill "$heartbeat_pid" 2> /dev/null
    wait "$heartbeat_pid" 2> /dev/null

    if [ $exit_code -ne 0 ]; then
        echo "       ❌ Warning: $label failed (Exit Code: $exit_code)."
        echo "       Check the end of $STARTUP_LOG for details."
        echo "END: $label (FAILED)" >> "$STARTUP_LOG"
    else
        echo "END: $label (SUCCESS)" >> "$STARTUP_LOG"
    fi

    echo -e "\n" >> "$STARTUP_LOG" # Add spacing between log entries
    return $exit_code
}

# Helper functions for cleaner output
status_msg() { echo -e "\n---> $1"; }

# ============================================================
# Try to find full tcmalloc first, fallback to minimal
# ============================================================

TCMALLOC_PATH=$(ldconfig -p 2> /dev/null | grep -E 'libtcmalloc\.so' | head -n1 | awk '{print $NF}')

if [ -z "$TCMALLOC_PATH" ]; then
    TCMALLOC_PATH=$(ldconfig -p 2> /dev/null | grep -E 'libtcmalloc_minimal\.so' | head -n1 | awk '{print $NF}')
fi

# Apply if found
if [ -n "$TCMALLOC_PATH" ]; then
    export LD_PRELOAD="$TCMALLOC_PATH"
    echo "Using tcmalloc: $TCMALLOC_PATH"
else
    echo "tcmalloc not found, skipping LD_PRELOAD"
fi

# ============================================================
# GPU detection
# ============================================================

if command -v nvidia-smi > /dev/null 2>&1; then

    readarray -t GPU_INFO < <(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2> /dev/null)

    DETECTED_GPU=$(echo "${GPU_INFO[0]}" | cut -d',' -f1 | xargs)

    CUDA_ARCH=$(printf "%s\n" "${GPU_INFO[@]}" \
        | cut -d',' -f2 \
        | sed 's/\.//g' \
        | sort -u \
        | xargs \
        | tr ' ' ';')

else
    DETECTED_GPU="Unknown GPU"
    CUDA_ARCH="80;86;89;90"
fi

# Final fallback
[ -z "$CUDA_ARCH" ] && CUDA_ARCH="80;86;89;90"

echo "$DETECTED_GPU" > /tmp/detected_gpu

# ============================================================
# Startup banner
# ============================================================

echo ""
echo "================================================"
echo "  Starting up..."
status_msg "Detected GPU: $DETECTED_GPU (Compute Capability: $CUDA_ARCH)"
echo "================================================"

# ============================================================
# Flash Attention
# ============================================================
status_msg "[1/4] Checking Flash Attention"

# Check if already installed (Crucial for persistent environments)
if python -c "import flash_attn" &> /dev/null; then
    status_msg "Flash Attention already installed. Skipping."
else
    # Only install if architecture supports it (Ampere+)
    if echo "$CUDA_ARCH" | grep -Eq '(^|;)(80|86|89|90|100|120)($|;)'; then
        status_msg "Supported architecture detected ($CUDA_ARCH). Installing Flash Attention..."

        PYTHON_VER=$(python -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")')
        TORCH_VER=$(python -c 'import torch; print(".".join(torch.__version__.split("+")[0].split(".")[:2]))')
        CUDA_VER="128"
        FLASH_ATTENTION_VER="2.8.3"

        FLASH_ATTN_WHEEL_URL="https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.5.4/flash_attn-${FLASH_ATTENTION_VER}+cu${CUDA_VER}torch${TORCH_VER}-cp${PYTHON_VER}-cp${PYTHON_VER}-linux_x86_64.whl"

        if pip install "$FLASH_ATTN_WHEEL_URL" --no-build-isolation >> "$STARTUP_LOG" 2>&1; then
            echo "FlashAttention installed via wheel" >> "$STARTUP_LOG"
        else
            echo "        -> Wheel install failed. Building from source in background..."
            (
                set -e
                cd /tmp
                rm -rf flash-attention
                git clone --depth 1 https://github.com/Dao-AILab/flash-attention.git
                cd flash-attention
                export FLASH_ATTN_CUDA_ARCHS="$CUDA_ARCH"
                export MAX_JOBS=$(nproc)
                export NVCC_THREADS=2
                pip install ninja packaging -q
                pip install . --no-build-isolation
                cd /tmp
                rm -rf flash-attention
            ) > "$NETWORK_VOLUME/logs/flash_attn_install.log" 2>&1 &

            FLASH_ATTN_PID=$!
            echo "$FLASH_ATTN_PID" > /tmp/flash_attn_pid
            echo "        -> Background build started (PID: $FLASH_ATTN_PID)"
        fi
    else
        status_msg "Unsupported architecture ($CUDA_ARCH). Skipping Flash Attention."
    fi
fi

# ============================================================
# Sage Attention (V2.x)
# ============================================================
status_msg "[2/4] Checking SageAttention"

if $PYTHON_BIN -c "import sageattention" &> /dev/null; then
    status_msg "SageAttention already installed. Skipping build."
    SAGE_ATTENTION_AVAILABLE=true
else
    # Only attempt install if NOT already installed AND architecture is supported
    if echo "$CUDA_ARCH" | grep -Eq '(^|;)(80|86|89|90|100|120)($|;)'; then
        status_msg "Supported architecture ($CUDA_ARCH) detected. Installing SageAttention 2..."
        run_quiet "SageAttention V2" pip install --no-cache-dir --no-build-isolation git+https://github.com/thu-ml/SageAttention.git@main

        # Link libcuda for the kernels
        ln -sf /usr/lib/x86_64-linux-gnu/libcuda.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so
        SAGE_ATTENTION_AVAILABLE=true
    else
        status_msg "Unsupported architecture ($CUDA_ARCH). Skipping SageAttention."
        SAGE_ATTENTION_AVAILABLE=false
    fi
fi

# ============================================================
# Setting up workspace
# ============================================================
status_msg "[3/4] Setting up workspace..."

echo "Starting JupyterLab in $NETWORK_VOLUME"
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser \
    --NotebookApp.token='' --NotebookApp.password='' \
    --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True \
    --notebook-dir="$NETWORK_VOLUME" &

# Ensure the database file path is clean
FB_DB="$NETWORK_VOLUME/filebrowser.db"

# 1. Initialize configuration only if it's a brand new volume
if [ ! -f "$FB_DB" ]; then
    echo "Creating a fresh Filebrowser database..."
    filebrowser -d "$FB_DB" config init

    # Hardcoded user to "admin", fallback password to "default_password" if env is missing
    filebrowser -d "$FB_DB" users add admin "${FB_PASSWORD:-default_password}" --perm.admin
fi

# 2. Start Filebrowser in the background
echo "Launching Filebrowser on port 8080..."
filebrowser -d "$FB_DB" -r "$NETWORK_VOLUME" -a 0.0.0.0 -p 8080 > "$NETWORK_VOLUME/filebrowser.log" 2>&1 &

# Define base paths
COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"
DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
CLIP_VISION_DIR="$NETWORK_VOLUME/ComfyUI/models/clip_vision"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"
LATENT_UPSCALE_DIR="$NETWORK_VOLUME/ComfyUI/models/latent_upscale_models"
UPSCALE_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/upscale_models"
LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"
CHECKPOINTS_DIR="$NETWORK_VOLUME/ComfyUI/models/checkpoints"
GGUF_DIR="$NETWORK_VOLUME/ComfyUI/models/unet"
DETECTION_DIR="$NETWORK_VOLUME/ComfyUI/models/detection"
AUDIO_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/audio_encoders"
LATENTSYNC_DIR="$NETWORK_VOLUME/ComfyUI/models/checkpoints/latentsync"
LIVEPORTRAIT_DIR="$NETWORK_VOLUME/ComfyUI/models/liveportrait"
INSIGHTFACE_DIR="$NETWORK_VOLUME/ComfyUI/models/insightface/models"
SAM2_DIR="$NETWORK_VOLUME/ComfyUI/models/sam2"
RIFE_DIR="$NETWORK_VOLUME/ComfyUI/models/rife"
FILM_DIR="$NETWORK_VOLUME/ComfyUI/models/film"
ULTRALYTICS_DIR="$NETWORK_VOLUME/ComfyUI/models/ultralytics"
ANTELOPEV2_DIR="$INSIGHTFACE_DIR/antelopev2"
BUFFALO_L_DIR="$INSIGHTFACE_DIR/buffalo_l"
ANIMATEDIFF_DIR="$NETWORK_VOLUME/ComfyUI/models/animatediff_models"
MOTION_LORA_DIR="$NETWORK_VOLUME/ComfyUI/models/animatediff_motion_lora"
IPADAPTER_DIR="$NETWORK_VOLUME/ComfyUI/models/ipadapter"
JOYCAPTION_DIR="$NETWORK_VOLUME/ComfyUI/models/LLavacheckpoints/llama-joycaption-beta-one-hf-llava"
FLORENCE2_DIR="$NETWORK_VOLUME/ComfyUI/models/florence2/base-PromptGen"
MODEL_WHITELIST_DIR="$NETWORK_VOLUME/ComfyUI/user/default/ComfyUI-Impact-Subpack/model-whitelist.txt"
mkdir -p "$CUSTOM_NODES_DIR"

if [ ! -d "$COMFYUI_DIR" ] || [ -z "$(ls -A "$COMFYUI_DIR" 2> /dev/null)" ]; then
    status_msg "First Boot: Moving ComfyUI to Volume..."
    mkdir -p "$COMFYUI_DIR"
    mv /ComfyUI/* "$COMFYUI_DIR"/ 2> /dev/null || true
    echo "✨ Pristine image deployed to volume. Skipping sync update for faster first boot."
else
    status_msg "Restart detected: Syncing latest Image changes to Volume..."
    # Force sync native core changes from your freshly built Docker image layers
    cp -ruvT /ComfyUI "$COMFYUI_DIR"
    rm -rf /ComfyUI
    echo "✅ Sync complete."

    # 🔄 SMART SYNC: Only engage on persistent storage restarts
    echo "🔄 Persistent storage detected. Checking for updates and new dependencies..."

    # Track actions taken
    updated_nodes=0
    patched_dependencies=0

    # Process Substitution avoids subshell isolation, keeping script execution native and safe
    while read -r node_path; do
        if [ -d "$node_path/.git" ]; then
            node_name=$(basename "$node_path")

            # Check the 'mtime' of both requirement files before pulling
            REQ_FILE="$node_path/requirements.txt"
            CUPY_FILE="$node_path/requirements-with-cupy.txt"

            BEFORE_MOD=0
            CUPY_BEFORE=0

            [ -f "$REQ_FILE" ] && BEFORE_MOD=$(stat -c %Y "$REQ_FILE" 2> /dev/null || stat -f %m "$REQ_FILE" 2> /dev/null)
            [ -f "$CUPY_FILE" ] && CUPY_BEFORE=$(stat -c %Y "$CUPY_FILE" 2> /dev/null || stat -f %m "$CUPY_FILE" 2> /dev/null)

            # Perform a defensive clean pull to ensure headless operation doesn't halt on local conflicts
            (
                cd "$node_path" \
                    && git reset --hard HEAD -q \
                    && git pull --ff-only -q
            ) > /dev/null 2>&1

            # Check for changes in either file post-pull
            AFTER_MOD=0
            CUPY_AFTER=0

            [ -f "$REQ_FILE" ] && AFTER_MOD=$(stat -c %Y "$REQ_FILE" 2> /dev/null || stat -f %m "$REQ_FILE" 2> /dev/null)
            [ -f "$CUPY_FILE" ] && CUPY_AFTER=$(stat -c %Y "$CUPY_FILE" 2> /dev/null || stat -f %m "$CUPY_FILE" 2> /dev/null)

            if [ "$BEFORE_MOD" != "$AFTER_MOD" ] || [ "$CUPY_BEFORE" != "$CUPY_AFTER" ]; then
                echo "📦 New dependencies detected for $node_name. Harmonizing and installing..."
                ((patched_dependencies++))

                # 🛡️ NODE-SPECIFIC PATCHES (ComfyUI-Frame-Interpolation)
                if [ "$node_name" = "ComfyUI-Frame-Interpolation" ] && [ -f "$CUPY_FILE" ]; then
                    echo "   🛠️ Applying node-specific patches for Frame-Interpolation cupy requirements..."
                    sed -i -E 's/opencv-(python|contrib-python)(-headless)?(\[[a-zA-Z0-9_-]+\])?(==[0-9.]+)?/opencv-contrib-python-headless/g' "$CUPY_FILE"
                    sed -i -E 's/^torch([>=<~= ]+[0-9.]+)?$/# torch already installed/g' "$CUPY_FILE"
                    sed -i -E 's/^torchvision([>=<~= ]+[0-9.]+)?$/# torchvision already installed/g' "$CUPY_FILE"
                    sed -i -E 's/^numpy([>=<~= ]+[0-9.]+)?$/# numpy already installed/g' "$CUPY_FILE"
                    sed -i -E 's/^[Pp]illow([>=<~= ]+[0-9.]+)?$/# Pillow already installed/g' "$CUPY_FILE"
                    sed -i -E 's/^cupy-wheel$/cupy-cuda12x/g' "$CUPY_FILE"
                fi

                # 🛡️ GENERAL DOCKERFILE HARMONIZATION PATCHES
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

                # Maintain a clean network disk footprint
                INSTALL_SUCCESS=true

                # Install standard requirements if they exist
                if [ -f "$REQ_FILE" ]; then
                    if ! $PYTHON_BIN -m pip install --no-cache-dir -r "$REQ_FILE" >> "$STARTUP_LOG" 2>&1; then
                        INSTALL_SUCCESS=false
                    fi
                fi

                # Ensure cupy requirements are installed if it's the Frame-Interpolation node
                if [ "$node_name" = "ComfyUI-Frame-Interpolation" ] && [ -f "$CUPY_FILE" ]; then
                    if ! $PYTHON_BIN -m pip install --no-cache-dir -r "$CUPY_FILE" >> "$STARTUP_LOG" 2>&1; then
                        INSTALL_SUCCESS=false
                    fi
                fi

                if [ "$INSTALL_SUCCESS" = true ]; then
                    echo "   ✅ Dependencies installed for $node_name"
                else
                    echo "   ❌ Dependency install failed for $node_name — check $STARTUP_LOG"
                fi
            fi
            ((updated_nodes++))
        fi
    done < <(find "$CUSTOM_NODES_DIR" -maxdepth 1 -type d -not -path "$CUSTOM_NODES_DIR")

    echo "✅ Smart Updater processed $updated_nodes custom nodes ($patched_dependencies required env patching)."
    echo "✅ All persistent nodes updated and dependencies verified."
fi

# Acquiring CivitAI Downloader and required models
echo "📥 Setting up CivitAI Downloader..."
if [ ! -f "/usr/local/bin/download_with_aria.py" ]; then
    $PYTHON_BIN -m pip install requests tqdm

    git clone "https://github.com/concreteshoes/CivitAI_Downloader.git" /tmp/CivitAI_Downloader || echo "Git clone failed"
    mv /tmp/CivitAI_Downloader/download_with_aria.py "/usr/local/bin/" || echo "Move failed"
    chmod +x "/usr/local/bin/download_with_aria.py" || echo "Chmod failed"
    rm -rf /tmp/CivitAI_Downloader
else
    echo "✅ CivitAI Downloader already exists."
fi

download_model() {
    local url="$1"
    local full_path="$2"
    local skip_size_check="${3:-false}"

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    if [ -f "${full_path}.aria2" ]; then
        echo "⏳ Partial download state found for $destination_file. Resuming..."

    elif [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2> /dev/null || stat -c%s "$full_path" 2> /dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))

        if [ "$size_bytes" -lt 10485760 ] && [ "$skip_size_check" != "true" ]; then
            echo "🗑️  Deleting corrupted placeholder file (${size_mb}MB < 10MB): $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists (${size_mb}MB), skipping download."
            LAST_DOWNLOAD_PID="" # ← clear it so caller knows no job was started
            return 0
        fi
    fi

    echo "📥 Background download scheduled for $destination_file..."
    aria2c -x 8 -s 8 -k 4M \
        --continue=true \
        --file-allocation=none \
        --max-tries=5 \
        --retry-wait=3 \
        --timeout=60 \
        --connect-timeout=10 \
        --console-log-level=error \
        -d "$destination_dir" \
        -o "$destination_file" \
        "$url" &
    LAST_DOWNLOAD_PID=$! # ← capture before anything else can overwrite $!
}

# ============================================================
# LTX 2.3
# ============================================================

if [ "${DOWNLOAD_LTX23_DEV_MXFP8:-}" = "true" ]; then
    echo "📥 Downloading LTX 2.3 mxfp8 dev & dependencies ..."
    download_model "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/diffusion_models/ltx-2.3-22b-dev_transformer_only_mxfp8_block32.safetensors" "$DIFFUSION_MODELS_DIR/ltx-2.3-22b-dev_transformer_only_mxfp8_block32.safetensors"

    # Download the text encoder
    download_model "https://huggingface.co/GitMylo/LTX-2-comfy_gemma_fp8_e4m3fn/resolve/main/gemma_3_12B_it_fp8_e4m3fn.safetensors" "$TEXT_ENCODERS_DIR/gemma_3_12B_it_fp8_e4m3fn.safetensors"
    download_model "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/text_encoders/ltx-2.3_text_projection_bf16.safetensors" "$TEXT_ENCODERS_DIR/ltx-2.3_text_projection_bf16.safetensors"

    #Download the VAE
    download_model "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_video_vae_bf16.safetensors" "$VAE_DIR/LTX23_video_vae_bf16.safetensors"
    download_model "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_audio_vae_bf16.safetensors" "$VAE_DIR/LTX23_audio_vae_bf16.safetensors"
    download_model "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/taeltx2_3.safetensors" "$VAE_DIR/taeltx2_3.safetensors"
fi

if [ "${DOWNLOAD_LTX23_DEV_GGUF_Q8:-}" = "true" ]; then
    echo "📥 Downloading LTX 2.3 dev GGUF Q8 & dependencies..."
    download_model "https://huggingface.co/unsloth/LTX-2.3-GGUF/resolve/main/ltx-2.3-22b-dev-Q8_0.gguf" "$GGUF_DIR/ltx-2.3-22b-dev-Q8_0.gguf"
    download_model "https://huggingface.co/unsloth/LTX-2.3-GGUF/resolve/main/text_encoders/ltx-2.3-22b-dev_embeddings_connectors.safetensors" "$TEXT_ENCODERS_DIR/ltx-2.3-22b-dev_embeddings_connectors.safetensors"

    # Download text encoder
    download_model "https://huggingface.co/unsloth/gemma-3-12b-it-GGUF/resolve/main/gemma-3-12b-it-UD-Q8_K_XL.gguf" "$TEXT_ENCODERS_DIR/gemma-3-12b-it-UD-Q8_K_XL.gguf"

    #Download the VAE
    download_model "https://huggingface.co/unsloth/LTX-2.3-GGUF/resolve/main/vae/ltx-2.3-22b-dev_audio_vae.safetensors" "$VAE_DIR/ltx-2.3-22b-dev_audio_vae.safetensors"
    download_model "https://huggingface.co/unsloth/LTX-2.3-GGUF/resolve/main/vae/ltx-2.3-22b-dev_video_vae.safetensors" "$VAE_DIR/ltx-2.3-22b-dev_video_vae.safetensors"
fi

if [ "${DOWNLOAD_LTX23_DEV_MXFP8:-}" = "true" ] || [ "${DOWNLOAD_LTX23_DEV_GGUF_Q8:-}" = "true" ]; then
    echo "📥 Downloading shared LTX 2.3 loras and upscalers..."

    # Download distilled loras
    download_model "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/loras/ltx-2.3-22b-distilled-1.1_lora-dynamic_fro09_avg_rank_111_bf16.safetensors" "$LORAS_DIR/ltx-2.3-22b-distilled-1.1_lora-dynamic_fro09_avg_rank_111_bf16.safetensors"

    # Download RL loras
    download_model "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/loras/LTX-2.3-OmniNFT-RL-Lora_bf16.safetensors" "$LORAS_DIR/LTX-2.3-OmniNFT-RL-Lora_bf16.safetensors"

    # Download LTX-2.3 latent upscalers
    download_model "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors" "$LATENT_UPSCALE_DIR/ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors"
    download_model "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors" "$LATENT_UPSCALE_DIR/ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
    download_model "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-temporal-upscaler-x2-1.0.safetensors" "$LATENT_UPSCALE_DIR/ltx-2.3-temporal-upscaler-x2-1.0.safetensors"

    echo "📋 LTX 2.3 pipeline queued for background download"
fi

# ============================================================
# WAN 2.2
# ============================================================

if [ "${DOWNLOAD_WAN22_T2V_FP8:-}" = "true" ]; then
    echo "📥 Downloading Wan 2.2 t2v fp8_e4m3fn_scaled models..."
    download_model "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/T2V/Wan2_2-T2V-A14B_HIGH_fp8_e4m3fn_scaled_KJ.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_2-T2V-A14B_HIGH_fp8_e4m3fn_scaled_KJ.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/T2V/Wan2_2-T2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_2-T2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors"

    # 4-Step Lightning Matrix T2V
    download_model "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V2.0/high_noise_model.safetensors" "$LORAS_DIR/t2v_lightx2v_high_noise_model.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V2.0/low_noise_model.safetensors" "$LORAS_DIR/t2v_lightx2v_low_noise_model.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_t2v_A14b_high_noise_lora_rank64_lightx2v_4step_1217.safetensors" "$LORAS_DIR/t2v_lightx2v_high_noise_1217.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_t2v_A14b_low_noise_lora_rank64_lightx2v_4step_1217.safetensors" "$LORAS_DIR/t2v_lightx2v_low_noise_1217.safetensors"
fi

if [ "${DOWNLOAD_WAN22_I2V_FP8:-}" = "true" ]; then
    echo "📥 Downloading Wan 2.2 i2v fp8_e4m3fn_scaled models..."
    download_model "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/I2V/Wan2_2-I2V-A14B-HIGH_fp8_e4m3fn_scaled_KJ.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_2-I2V-A14B-HIGH_fp8_e4m3fn_scaled_KJ.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/I2V/Wan2_2-I2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_2-I2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors"

    # 4-Step Lightning Matrix I2V
    download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors" "$LORAS_DIR/i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors" "$LORAS_DIR/i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors"

    # Alternative I2V Step-Distill Models (Kijai Comfy Variant)
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_260412_rank_64_fp16.safetensors" "$LORAS_DIR/I2V_A14B_HIGH_lightx2v_4step_lora_260412_rank_64_fp16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_LOW_lightx2v_4step_lora_260412_rank_64_fp16.safetensors" "$LORAS_DIR/I2V_A14B_LOW_lightx2v_4step_lora_260412_rank_64_fp16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_260412_rank_256_fp16.safetensors" "$LORAS_DIR/I2V_A14B_HIGH_lightx2v_4step_lora_260412_rank_256_fp16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_LOW_lightx2v_4step_lora_260412_rank_256_fp16.safetensors" "$LORAS_DIR/I2V_A14B_LOW_lightx2v_4step_lora_260412_rank_256_fp16.safetensors"

    # Stable Video Infinity v2 PRO Modules
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors" "$LORAS_DIR/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors" "$LORAS_DIR/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors"
fi

if [ "${DOWNLOAD_WAN22_SVI_NSFW_FP8:-}" = "true" ]; then
    echo "📥 Downloading Wan 2.2 nsfw SVI fp8_e4m3fn models..."
    download_model "https://huggingface.co/rgomezs2010/loras_wan/resolve/7631c58e89a5e045825d9ecc6de7888d8f613f33/wan22EnhancedNSFWSVICamera_nolightningSVICfFp8H.safetensors" "$DIFFUSION_MODELS_DIR/wan22EnhancedNSFWSVICamera_nolightningSVICfFp8H.safetensors"
    download_model "https://huggingface.co/rgomezs2010/loras_wan/resolve/7631c58e89a5e045825d9ecc6de7888d8f613f33/wan22EnhancedNSFWSVICamera_nolightningSVICfFp8L.safetensors" "$DIFFUSION_MODELS_DIR/wan22EnhancedNSFWSVICamera_nolightningSVICfFp8L.safetensors"
fi

# ============================================================
# WAN 2.2 ANIMATE & POSE ECOSYSTEM (SteadyDancer Replacements)
# ============================================================

if [ "${DOWNLOAD_WAN_ANIMATE_FP8:-}" = "true" ]; then
    echo "📥 Downloading Wan 2.2 Animate fp8_scaled_e4m3fn model & infrastructure..."
    download_model "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/Wan22Animate/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_animate_14B_relight_lora_bf16.safetensors" "$LORAS_DIR/wan2.2_animate_14B_relight_lora_bf16.safetensors"

    # Tracking Detection matrices for ComfyUI-WanAnimatePreprocess & SCAIL
    echo "📥 Downloading Wan Animate pose & object detection models..."
    download_model "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" "$DETECTION_DIR/yolov10m.onnx"
    download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" "$DETECTION_DIR/vitpose_h_wholebody_data.bin"
    download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" "$DETECTION_DIR/vitpose_h_wholebody_model.onnx"
fi

# ============================================================
# WAN 2.2 SPEECH-TO-VIDEO
# ============================================================

if [ "${DOWNLOAD_WAN_S2V_FP8:-}" = "true" ]; then
    echo "📥 Downloading Wan 2.2 S2V fp8_e4m3fn_scaled lip-sync layers..."
    download_model "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/S2V/Wan2_2-S2V-14B_fp8_e4m3fn_scaled_KJ.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_2-S2V-14B_fp8_e4m3fn_scaled_KJ.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/audio_encoders/wav2vec2_large_english_fp16.safetensors" "$AUDIO_ENCODERS_DIR/wav2vec2_large_english_fp16.safetensors"
fi

# ============================================================
# WAN 2.2 STRUCTURE & MOTION CONTROL (SteadyDancer Replacements)
# ============================================================

# 1. Wan 2.2 Fun Control Engine (Native Multi-Modal Pose/Depth/Canny Base)
if [ "${DOWNLOAD_WAN_FUN_CONTROL_FP8:-}" = "true" ]; then
    echo "📥 Downloading Wan 2.2 fp8 Fun Control fp8_e4m3fn_scaled models..."

    # Official Alibaba PAI Wan 2.2 Fun base checkpoints split for ComfyUI Native/Kijai wrappers
    download_model "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/Fun/Wan2_2-Fun-Control-A14B-HIGH_fp8_e4m3fn_scaled_KJ_fixed.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_2-Fun-Control-A14B-HIGH_fp8_e4m3fn_scaled_KJ_fixed.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/Fun/Wan2_2-Fun-Control-A14B-LOW_fp8_e4m3fn_scaled_KJ_fixed.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_2-Fun-Control-A14B-LOW_fp8_e4m3fn_scaled_KJ_fixed.safetensors"
fi

# 2. Dedicated Wan 2.2 ControlNet Adapters
if [ "${DOWNLOAD_WAN_CONTROLNETS:-}" = "true" ]; then
    echo "📥 Downloading Wan 2.2 ControlNet adapters..."

    # TheDenk Verified Wan 2.2 14B Depth ControlNet
    download_model "https://huggingface.co/TheDenk/wan2.2-t2v-a14b-controlnet-depth-v1/resolve/main/diffusion_pytorch_model.safetensors" "$CONTROLNET_DIR/wan2.2_t2v_a14b_controlnet_depth_v1.safetensors"

    # TheDenk Verified Wan 2.2 14B HED/Edge ControlNet (Optional but highly recommended for posture layout)
    download_model "https://huggingface.co/TheDenk/wan2.2-t2v-a14b-controlnet-hed-v1/resolve/main/diffusion_pytorch_model.safetensors" "$CONTROLNET_DIR/wan2.2_t2v_a14b_controlnet_hed_v1.safetensors"
fi

# ============================================================
# WAN 2.2 TEXT ENCODER, VAE & OTHER ASSETS
# ============================================================

if [ "${DOWNLOAD_WAN22_T2V_FP8:-}" = "true" ] || [ "${DOWNLOAD_WAN22_I2V_FP8:-}" = "true" ] || [ "${DOWNLOAD_WAN22_SVI_NSFW_FP8:-}" = "true" ] || [ "${DOWNLOAD_WAN_ANIMATE_FP8:-}" = "true" ] || [ "${DOWNLOAD_WAN_S2V_FP8:-}" = "true" ] || [ "${DOWNLOAD_WAN_FUN_CONTROL_FP8:-}" = "true" ]; then
    echo "📥 Downloading Wan VAE, text encoder and clip vision arrays..."
    download_model "https://huggingface.co/NSFW-API/NSFW-Wan-UMT5-XXL/resolve/main/nsfw_wan_umt5-xxl_fp8_scaled.safetensors" "$TEXT_ENCODERS_DIR/nsfw_wan_umt5-xxl_fp8_scaled.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" "$TEXT_ENCODERS_DIR/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$CLIP_VISION_DIR/clip_vision_h.safetensors"
    download_model "https://huggingface.co/MonsterMMORPG/Wan_GGUF/resolve/main/Wan2_1_VAE_bf16.safetensors" "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/taew2_2.safetensors" "$VAE_DIR/taew2_2.safetensors"

    echo "📋 Wan 2.2 pipeline queued for background download"
fi

# ==========================================
# JOYCAPTION BETA ONE
# ==========================================

if [ "${DOWNLOAD_JOYCAPTION:-}" = "true" ]; then
    echo "📥 Downloading JoyCaption Beta One..."

    # 1. Config & Tokenizer Files
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/config.json" "$JOYCAPTION_DIR/config.json" true
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/generation_config.json" "$JOYCAPTION_DIR/generation_config.json" true
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model.safetensors.index.json" "$JOYCAPTION_DIR/model.safetensors.index.json" true
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/preprocessor_config.json" "$JOYCAPTION_DIR/preprocessor_config.json" true
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/special_tokens_map.json" "$JOYCAPTION_DIR/special_tokens_map.json" true
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/tokenizer.json" "$JOYCAPTION_DIR/tokenizer.json" true
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/tokenizer_config.json" "$JOYCAPTION_DIR/tokenizer_config.json" true

    # 2. Sharded Weights
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model-00001-of-00004.safetensors" "$JOYCAPTION_DIR/model-00001-of-00004.safetensors"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model-00002-of-00004.safetensors" "$JOYCAPTION_DIR/model-00002-of-00004.safetensors"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model-00003-of-00004.safetensors" "$JOYCAPTION_DIR/model-00003-of-00004.safetensors"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model-00004-of-00004.safetensors" "$JOYCAPTION_DIR/model-00004-of-00004.safetensors"

    echo "📋 JoyCaption Beta One model queued for background download"
fi

# ==========================================
# FLORENCE-2 NSFW V2
# ==========================================

if [ "${DOWNLOAD_FLORENCE2:-}" = "true" ]; then
    echo "📥 Downloading Florence-2 NSFW finetune..."

    # Base URL for the finetune
    NSFW_BASE_URL="https://huggingface.co/ljnlonoljpiljm/florence-2-base-nsfw-v2/resolve/main"

    # 1. Core Configuration & Tokenizer
    download_model "$NSFW_BASE_URL/config.json" "$FLORENCE2_DIR/config.json" true
    download_model "$NSFW_BASE_URL/generation_config.json" "$FLORENCE2_DIR/generation_config.json" true
    download_model "$NSFW_BASE_URL/preprocessor_config.json" "$FLORENCE2_DIR/preprocessor_config.json" true
    download_model "$NSFW_BASE_URL/added_tokens.json" "$FLORENCE2_DIR/added_tokens.json" true
    download_model "$NSFW_BASE_URL/merges.txt" "$FLORENCE2_DIR/merges.txt" true
    download_model "$NSFW_BASE_URL/special_tokens_map.json" "$FLORENCE2_DIR/special_tokens_map.json" true
    download_model "$NSFW_BASE_URL/tokenizer.json" "$FLORENCE2_DIR/tokenizer.json" true
    download_model "$NSFW_BASE_URL/tokenizer_config.json" "$FLORENCE2_DIR/tokenizer_config.json" true
    download_model "$NSFW_BASE_URL/vocab.json" "$FLORENCE2_DIR/vocab.json" true

    # 2. The Weights
    download_model "$NSFW_BASE_URL/model.safetensors" "$FLORENCE2_DIR/model.safetensors"

    # 3. Microsoft Processor (Handles the actual image bounding boxes/cropping)
    download_model "https://huggingface.co/microsoft/Florence-2-base/resolve/main/processing_florence2.py" "$FLORENCE2_DIR/processing_florence2.py" true

    # 4. APPLY THE KIJAI / LAYERSTYLE PATCH
    # We copy the patched modeling and config files directly from the custom node directory
    # to overwrite any missing or outdated files, ensuring transformers >= 4.45 compatibility.
    echo "🔧 Applying Transformers compatibility patch for Florence-2..."
    LAYERSTYLE_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI_LayerStyle_Advance/florence2_models"

    if [ -d "$LAYERSTYLE_MODELS_DIR" ]; then
        cp "$LAYERSTYLE_MODELS_DIR/modeling_florence2.py" "$FLORENCE2_DIR/"
        cp "$LAYERSTYLE_MODELS_DIR/configuration_florence2.py" "$FLORENCE2_DIR/"
        echo "✅ Florence-2 patched successfully."
    else
        echo "⚠️ WARNING: LayerStyle advance folder not found at $LAYERSTYLE_MODELS_DIR. Patch skipped."
    fi

    echo "📋 Florence-2 NSFW model queued for background download"
fi

# ==========================================
# LATENTSYNC
# ==========================================

echo "📥 Downloading LipSync weights..."
# Main LatentSync v1.6 Core Models
download_model "https://huggingface.co/ByteDance/LatentSync-1.6/resolve/main/latentsync_unet.pt" "$LATENTSYNC_DIR/latentsync_unet.pt"
download_model "https://huggingface.co/ByteDance/LatentSync-1.6/resolve/main/latentsync_syncnet.pt" "$LATENTSYNC_DIR/latentsync_syncnet.pt"

# Audio Encoder (Whisper)
download_model "https://huggingface.co/ByteDance/LatentSync/resolve/main/whisper/tiny.pt" "$LATENTSYNC_DIR/whisper/tiny.pt"

# Auxiliary Models (Face Detection & Parsing)
download_model "https://huggingface.co/ByteDance/LatentSync/resolve/main/auxiliary/79999_iter.pth" "$LATENTSYNC_DIR/auxiliary/79999_iter.pth"
download_model "https://huggingface.co/ByteDance/LatentSync/resolve/main/auxiliary/s3fd-619a316812.pth" "$LATENTSYNC_DIR/auxiliary/s3fd-619a316812.pth"
download_model "https://huggingface.co/ByteDance/LatentSync/resolve/main/auxiliary/2DFAN4-cd938726ad.zip" "$LATENTSYNC_DIR/auxiliary/2DFAN4-cd938726ad.zip"
download_model "https://huggingface.co/ByteDance/LatentSync/resolve/main/auxiliary/vgg16-397923af.pth" "$LATENTSYNC_DIR/auxiliary/vgg16-397923af.pth"

# VAE (Standard SD1.5 VAE required by LatentSync)
download_model "https://huggingface.co/ByteDance/LatentSync/resolve/main/vae/config.json" "$LATENTSYNC_DIR/vae/config.json" true
download_model "https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors" "$LATENTSYNC_DIR/vae/diffusion_pytorch_model.safetensors"

# ==========================================
# LIVEPORTRAIT
# ==========================================

echo "📥 Downloading LivePortrait weights..."
# Main Safetensors (Optimized for ComfyUI)
download_model "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/appearance_feature_extractor.safetensors" "$LIVEPORTRAIT_DIR/appearance_feature_extractor.safetensors"
download_model "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/motion_extractor.safetensors" "$LIVEPORTRAIT_DIR/motion_extractor.safetensors"
download_model "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/warping_module.safetensors" "$LIVEPORTRAIT_DIR/warping_module.safetensors"
download_model "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/spade_generator.safetensors" "$LIVEPORTRAIT_DIR/spade_generator.safetensors"
download_model "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/stitching_retargeting_module.safetensors" "$LIVEPORTRAIT_DIR/stitching_retargeting_module.safetensors"

# Landmark Model
# Kijai's node usually searches for this directly in the root of /liveportrait or in a /landmarks subfolder.
# It is safest to put it in both or use the root as defined below:
download_model "https://huggingface.co/Kijai/LivePortrait_safetensors/resolve/main/landmark.safetensors" "$LIVEPORTRAIT_DIR/landmark.safetensors"

# ==========================================
# ANIMATEDIFF-EVOLVED
# ==========================================

echo "📥 Downloading AnimateDiff-Evolved weights..."
# The Core SD1.5 Motion Modules
# V3 (Best Quality)
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/v3_sd15_mm.ckpt" "$ANIMATEDIFF_DIR/v3_sd15_mm.ckpt"
# V2 (Best Compatibility)
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/mm_sd_v15_v2.ckpt" "$ANIMATEDIFF_DIR/mm_sd_v15_v2.ckpt"

# AnimateLCM (For extremely fast generation)
download_model "https://huggingface.co/wangfuyun/AnimateLCM/resolve/main/AnimateLCM_sd15_t2v.ckpt" "$ANIMATEDIFF_DIR/AnimateLCM_sd15_t2v.ckpt"

# SDXL Motion Module (Optional, but good to have if you use SDXL checkpoints)
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/mm_sdxl_v10_beta.ckpt" "$ANIMATEDIFF_DIR/mm_sdxl_v10_beta.ckpt"

# Download the official V2 Camera Controls (These work best with mm_sd_v15_v2.ckpt)
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/v2_lora_PanLeft.ckpt" "$MOTION_LORA_DIR/v2_lora_PanLeft.ckpt"
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/v2_lora_PanRight.ckpt" "$MOTION_LORA_DIR/v2_lora_PanRight.ckpt"
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/v2_lora_TiltUp.ckpt" "$MOTION_LORA_DIR/v2_lora_TiltUp.ckpt"
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/v2_lora_TiltDown.ckpt" "$MOTION_LORA_DIR/v2_lora_TiltDown.ckpt"
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/v2_lora_ZoomIn.ckpt" "$MOTION_LORA_DIR/v2_lora_ZoomIn.ckpt"
download_model "https://huggingface.co/guoyww/animatediff/resolve/main/v2_lora_ZoomOut.ckpt" "$MOTION_LORA_DIR/v2_lora_ZoomOut.ckpt"

# ==========================================
# SAM 2 & RIFE
# ==========================================

echo "📥 Downloading SAM 2 & RIFE weights..."
download_model "https://huggingface.co/Kijai/sam2-safetensors/resolve/main/sam2.1_hiera_large-fp16.safetensors" "$SAM2_DIR/sam2.1_hiera_large-fp16.safetensors"
download_model "https://huggingface.co/Kijai/sam2-safetensors/resolve/main/sam2.1_hiera_small-fp16.safetensors" "$SAM2_DIR/sam2.1_hiera_small-fp16.safetensors"
download_model "https://huggingface.co/MachineDelusions/RIFE/resolve/main/rife49.pth" "$RIFE_DIR/rife49.pth"
download_model "https://huggingface.co/MachineDelusions/RIFE/resolve/main/film_net_fp32.pt" "$FILM_DIR/film_net_fp32.pt"

# ==========================================
# IMPACT PACK
# ==========================================

echo "📥 Downloading detailers & post-processing utilities..."
download_model "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov11l.pt" "$ULTRALYTICS_DIR/bbox/face_yolov11l.pt"
download_model "https://huggingface.co/Ultralytics/assets/resolve/main/yolo11l-seg.pt" "$ULTRALYTICS_DIR/segm/yolo11l-seg.pt"

# ==========================================
# IPADAPTER PLUS
# ==========================================

echo "📥 Downloading IP-Adapter weights..."
# CLIP Vision (The Image Encoder)
# This is the standard ViT-H model required by almost all IPAdapters
download_model "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" "$CLIP_VISION_DIR/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"

# IPAdapter Face Models (For Character Consistency)
# SD 1.5 Face Plus (Great for fast AnimateDiff face consistency)
download_model "https://huggingface.co/h94/IP-Adapter/resolve/main/models/ip-adapter-plus-face_sd15.safetensors" "$IPADAPTER_DIR/ip-adapter-plus-face_sd15.safetensors"

# SDXL Face Plus (Great for high-res base images before Wan I2V)
download_model "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus-face_sdxl_vit-h.safetensors" "$IPADAPTER_DIR/ip-adapter-plus-face_sdxl_vit-h.safetensors"

echo "📋 Dependency weights queued for background download"

if [ ! -f "$ULTRALYTICS_DIR/bbox/Eyes.pt" ]; then
    if [ -f "/Eyes.pt" ]; then
        mv "/Eyes.pt" "$ULTRALYTICS_DIR/bbox/Eyes.pt"
        echo "Moved Eyes.pt to the correct location."
    else
        echo "Eyes.pt not found in the root directory."
    fi
else
    echo "Eyes.pt already exists. Skipping."
fi

if [ ! -f "$UPSCALE_MODELS_DIR/4xLSDIR.pth" ]; then
    if [ -f "/4xLSDIR.pth" ]; then
        mv "/4xLSDIR.pth" "$UPSCALE_MODELS_DIR/4xLSDIR.pth"
        echo "Moved 4xLSDIR.pth to the correct location."
    else
        echo "4xLSDIR.pth not found in the root directory."
    fi
else
    echo "4xLSDIR.pth already exists. Skipping."
fi

# ============================================================
# OPTIMIZED ANTELOPEV2 ENGINE (Integrated with custom fn)
# ============================================================

# Only trigger if the target directory doesn't have the final .onnx models
if [ ! -d "$ANTELOPEV2_DIR" ] || [ -z "$(ls -A "$ANTELOPEV2_DIR" 2> /dev/null | grep '\.onnx$')" ]; then
    echo "📥 AntelopeV2 models missing. Launching download allocation..."

    # Call your custom function
    download_model "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip" "$ANTELOPEV2_DIR/antelopev2.zip"

    if [ ! -f "$ANTELOPEV2_DIR/antelopev2.zip" ] || [ -f "$ANTELOPEV2_DIR/antelopev2.zip.aria2" ]; then
        echo "⏳ Active download detected. Holding script execution until aria2c finishes..."
        wait "$LAST_DOWNLOAD_PID" 2> /dev/null || true
    fi

    # Proceed to extraction now that the file is fully on disk
    if [ -f "$ANTELOPEV2_DIR/antelopev2.zip" ]; then
        echo "📦 Extracting and flattening AntelopeV2 assets..."
        unzip -oj "$ANTELOPEV2_DIR/antelopev2.zip" -d "$ANTELOPEV2_DIR"

        echo "🧹 Cleaning up zip archive to keep network volume clean..."
        rm -f "$ANTELOPEV2_DIR/antelopev2.zip"
        echo "✅ AntelopeV2 engine deployment complete."
    fi
else
    echo "✅ AntelopeV2 models already present and extracted. Skipping setup."
fi

# ============================================================
# OPTIMIZED BUFFALO_L ENGINE
# ============================================================

# Only trigger if the target directory doesn't have the final .onnx models
if [ ! -d "$BUFFALO_L_DIR" ] || [ -z "$(ls -A "$BUFFALO_L_DIR" 2> /dev/null | grep '\.onnx$')" ]; then
    echo "📥 Buffalo_L models missing. Launching download allocation..."

    # Call your custom function
    download_model "https://huggingface.co/vladmandic/insightface-faceanalysis/resolve/main/buffalo_l.zip" "$BUFFALO_L_DIR/buffalo_l.zip"
    if [ ! -f "$BUFFALO_L_DIR/buffalo_l.zip" ] || [ -f "$BUFFALO_L_DIR/buffalo_l.zip.aria2" ]; then
        echo "⏳ Active download detected. Holding script execution until aria2c finishes..."
        wait "$LAST_DOWNLOAD_PID" 2> /dev/null || true
    fi

    # Proceed to extraction now that the file is fully on disk
    if [ -f "$BUFFALO_L_DIR/buffalo_l.zip" ]; then
        echo "📦 Extracting and flattening Buffalo_L assets..."
        unzip -oj "$BUFFALO_L_DIR/buffalo_l.zip" -d "$BUFFALO_L_DIR"

        echo "🧹 Cleaning up zip archive to keep network volume clean..."
        rm -f "$BUFFALO_L_DIR/buffalo_l.zip"
        echo "✅ Buffalo_L engine deployment complete."
    fi
else
    echo "✅ Buffalo_L models already present and extracted. Skipping setup."
fi

# ============================================================
# WORKFLOWS MIGRATION
# ============================================================

SOURCE_DIR="/comfyui-video/workflows"

# Ensure destination directory exists
mkdir -p "$WORKFLOW_DIR"

if [ -d "$SOURCE_DIR" ] && [ "$(ls -A "$SOURCE_DIR" 2> /dev/null)" ]; then
    echo "🔄 Migrating workflows and subfolders cleanly..."

    # rsync safely merges contents. If a folder exists, it adds new files inside it
    # without deleting old ones.
    rsync -av --ignore-existing "$SOURCE_DIR/" "$WORKFLOW_DIR/" > /dev/null

    # Wipe the source directory clean now that everything is safely copied/merged
    rm -rf "$SOURCE_DIR"/*
    echo "✅ Workflow migration and merge complete!"
else
    echo "✨ No source workflows found for migration."
fi

# ============================================================
# SURFACE EMBEDDED NODE WORKFLOWS
# ============================================================

WORKFLOW_EXPORT_DIR="$NETWORK_VOLUME/Workflows/Node_Examples"
mkdir -p "$WORKFLOW_EXPORT_DIR"

echo "🔗 Symlinking embedded node workflows for easy access..."

# 1. We look inside common directory structures to avoid dragging in non-workflow config.json files
# 2. We use relative path mapping to preserve nested folders (like i2v vs t2v examples)
find "$NETWORK_VOLUME/ComfyUI/custom_nodes" -type f -name "*.json" \
    \( -path "*/example_workflows/*" -o -path "*/examples/*" -o -path "*/workflows/*" \) | while read -r workflow_path; do

    # Extract the relative path path starting right after /custom_nodes/
    # This turns a deep path into 'ComfyUI-WanAnimatePreprocess/example_workflows/i2v/example.json'
    relative_path=$(echo "$workflow_path" | awk -F'/custom_nodes/' '{print $2}')

    # Determine the target path inside your export directory
    target_link_path="$WORKFLOW_EXPORT_DIR/$relative_path"

    # Ensure the parent folders exist cleanly inside the export tree
    mkdir -p "$(dirname "$target_link_path")"

    # Create the relative or absolute target mapping symlink safely
    ln -sf "$workflow_path" "$target_link_path"
done

echo "✅ Node example symlinking engine execution complete!"

# ============================================================
# COMFYUI IMPACT SUBPACK CONFIGURATION
# ============================================================

echo "📋 Ensuring ComfyUI-Impact-Subpack user directory exists..."
# Extracts the parent directory path dynamically to avoid creating a folder named '.txt'
mkdir -p "$(dirname "$MODEL_WHITELIST_DIR")"

echo "🔒 Writing model whitelist overrides..."
cat > "$MODEL_WHITELIST_DIR" << 'EOF'
Eyes.pt
face_yolov11l.pt
yolo11l-seg.pt
film_net_fp32.pt
EOF

echo "✅ Model whitelist successfully initialized!"

# ============================================================
# DYNAMIC CIVITAI DOWNLOAD ENGINE
# ============================================================

# Ensure the new UNET target path exists on the volume if GGUF downloads are requested
if [ -n "$GGUF_IDS_TO_DOWNLOAD" ] && [ "$GGUF_IDS_TO_DOWNLOAD" != "replace_with_ids" ]; then
    mkdir -p "$GGUF_DIR"
fi

# Initialize a clean, empty associative array
declare -A MODEL_CATEGORIES

# Dynamically populate the map to guarantee absolute syntax safety on empty environment variables
[ -n "$CHECKPOINT_IDS_TO_DOWNLOAD" ] && MODEL_CATEGORIES["$CHECKPOINTS_DIR"]="$CHECKPOINT_IDS_TO_DOWNLOAD"
[ -n "$LORAS_IDS_TO_DOWNLOAD" ] && MODEL_CATEGORIES["$LORAS_DIR"]="$LORAS_IDS_TO_DOWNLOAD"
[ -n "$BASE_MODEL_IDS_TO_DOWNLOAD" ] && MODEL_CATEGORIES["$DIFFUSION_MODELS_DIR"]="$BASE_MODEL_IDS_TO_DOWNLOAD"
[ -n "$GGUF_IDS_TO_DOWNLOAD" ] && MODEL_CATEGORIES["$GGUF_DIR"]="$GGUF_IDS_TO_DOWNLOAD"

# Counter and PID tracking
download_count=0
download_pids=()

# Schedule downloads in background
for TARGET_DIR in "${!MODEL_CATEGORIES[@]}"; do
    MODEL_IDS_STRING="${MODEL_CATEGORIES[$TARGET_DIR]}"

    if [[ "$MODEL_IDS_STRING" == "replace_with_ids" ]]; then
        echo "⏭️  Skipping downloads for $TARGET_DIR (Default placeholder detected)"
        continue
    fi

    IFS=',' read -ra MODEL_IDS <<< "$MODEL_IDS_STRING"
    for MODEL_ID in "${MODEL_IDS[@]}"; do
        CLEAN_ID="${MODEL_ID// /}"
        [ -z "$CLEAN_ID" ] && continue

        echo "🚀 Scheduling CivitAI download: $CLEAN_ID to $TARGET_DIR"
        (cd "$TARGET_DIR" && $PYTHON_BIN /usr/local/bin/download_with_aria.py -m "$CLEAN_ID") &
        download_pids+=($!)
        ((download_count++))
    done
done

echo "📋 Scheduled $download_count downloads in background."

# ============================================================
# CRITICAL BOUNDARY: Block thread until background jobs finish
# ============================================================

if [ "$download_count" -gt 0 ]; then
    echo "⏳ Holding boot sequence: Waiting for $download_count background model downloads to complete..."
    wait "${download_pids[@]}"
    echo "✅ All background model downloads have finished successfully!"
else
    echo "✅ No background downloads were required."
fi

# Final catch-all safety wall for any lingering aria2c tasks
if pgrep -x "aria2c" > /dev/null; then
    echo "⏳ Waiting for lingering aria2c processes to completely close..."
    while pgrep -x "aria2c" > /dev/null; do
        sleep 5
    done
fi

echo "✅ All models downloaded successfully!"

# ============================================================
# ComfyUI
# ============================================================

echo "Updating default preview method..."
CONFIG_PATH="$NETWORK_VOLUME/ComfyUI/user/default/ComfyUI-Manager"
CONFIG_FILE="$CONFIG_PATH/config.ini"

# Ensure the directory exists
mkdir -p "$CONFIG_PATH"

# Create the config file if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config.ini..."
    cat << EOL > "$CONFIG_FILE"
[default]
preview_method = auto
git_exe =
use_uv = False
channel_url = https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main
# 1. Block unauthorized external network sharing
share_option = none
bypass_ssl = False
file_logging = True
component_policy = workflow
# 2. Lock down core ComfyUI updates completely
update_policy = none
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
# 3. Elevate security to block background pip executions
security_level = high
skip_migration_check = False
always_lazy_install = False
network_mode = public
db_mode = cache
EOL
else
    echo "config.ini already exists. Updating preview_method..."
    sed -i 's/^preview_method = .*/preview_method = auto/' "$CONFIG_FILE"
fi
echo "Config file setup complete!"
echo "Default preview method updated to 'auto'"

# Workspace as main working directory
grep -qxF "cd $NETWORK_VOLUME" ~/.bashrc || echo "cd $NETWORK_VOLUME" >> ~/.bashrc

# Return to the ComfyUI root directory before launching
cd "$NETWORK_VOLUME/ComfyUI" || exit 1

# GPU VRAM check
# Grabs the total memory of the first GPU in MB
GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
VRAM_THRESHOLD=32000 # 32GB in MB

# Start with base flags
LAUNCH_FLAGS="--listen --preview-method auto"

# Add FP8 flags if enabled
#if [ "${USE_FP8_TEXT_ENC:-true}" = "true" ]; then
#    LAUNCH_FLAGS="$LAUNCH_FLAGS --fp8_e4m3fn-text-enc"
#    status_msg "FP8 text encoder enabled"
#fi

#if [ "${USE_FP8_MODEL:-}" = "true" ]; then
#    LAUNCH_FLAGS="$LAUNCH_FLAGS --fp8_e4m3fn-unet"
#    status_msg "FP8 model weight casting enabled (E4M3FN)"
#fi

# Memory Optimization based on VRAM
if [ "$GPU_VRAM_MB" -ge "$VRAM_THRESHOLD" ]; then
    echo "🚀 High VRAM detected (32GB+). Enabling --highvram."
    LAUNCH_FLAGS="$LAUNCH_FLAGS --highvram"
else
    echo "⚖️ Standard VRAM detected. Letting ComfyUI handle dynamic offloading."
fi

# Add SageAttention
if [ "$SAGE_ATTENTION_AVAILABLE" = "true" ]; then
    LAUNCH_FLAGS="$LAUNCH_FLAGS --use-sage-attention"
fi

# Final Command Construction
COMFYUI_CMD="$PYTHON_BIN ./main.py $LAUNCH_FLAGS"

# Launch
URL="http://127.0.0.1:8188"
status_msg "▶️ Starting ComfyUI with flags: $LAUNCH_FLAGS"
nohup $COMFYUI_CMD > "$NETWORK_VOLUME/comfyui_nohup.log" 2>&1 &
echo $! > /tmp/comfyui.pid # Save PID for restart

# ============================================================
# LIVE-EVALUATION RESTART SCRIPT GENERATION
# ============================================================

# We use a quoted heredoc 'EOF' here to keep the inner variables intact for live runtime evaluation!
cat << 'EOF' > /usr/local/bin/comfyui-restart
#!/bin/bash

# Live-resolve environment paths
PYTHON_BIN="/usr/bin/python3"
COMFYUI_DIR=$(pwd)
LOG_FILE="comfyui_nohup.log"

# Catch accidental out-of-directory executions
if [ ! -f "./main.py" ] && [ -d "/workspace/ComfyUI" ]; then
    COMFYUI_DIR="/workspace/ComfyUI"
fi

# Detect log path safety
[ -f "../comfyui_nohup.log" ] && LOG_FILE="../comfyui_nohup.log"

echo "🛑 Stopping running ComfyUI process..."
kill $(cat /tmp/comfyui.pid 2>/dev/null) 2>/dev/null
sleep 2

# RE-EVALUATE HARDWARE ENVIRONMENT LIVE
# This ensures that if they change VRAM templates or switch configurations, the flags follow them.
GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
VRAM_THRESHOLD=32000

BASE_FLAGS="--listen --preview-method auto"

# Add FP8 flags if enabled
#if [ "${USE_FP8_TEXT_ENC:-true}" = "true" ]; then
#    LAUNCH_FLAGS="$LAUNCH_FLAGS --fp8_e4m3fn-text-enc"
#    status_msg "FP8 text encoder enabled"
#fi

#if [ "${USE_FP8_MODEL:-}" = "true" ]; then
#    LAUNCH_FLAGS="$LAUNCH_FLAGS --fp8_e4m3fn-unet"
#    status_msg "FP8 model weight casting enabled (E4M3FN)"
#fi

# Seamlessly check variable states inside the live shell container
if [ "$GPU_VRAM_MB" -ge "$VRAM_THRESHOLD" ]; then
    BASE_FLAGS="$BASE_FLAGS --highvram"
fi

# Live Python execution test to see if SageAttention compiles/loads cleanly right now
if /usr/bin/python3 -c "import sageattention" &> /dev/null; then
    echo "⚡ SageAttention import verification: SUCCESS. Appending launch flag."
    BASE_FLAGS="$BASE_FLAGS --use-sage-attention"
else
    echo "⚠️ SageAttention import verification: FAILED or missing. Omitting flag."
fi

echo "📋 Active debugger flags: $BASE_FLAGS"
if [ ! -z "$*" ]; then
    echo "🔧 User-appended arguments: $*"
fi

cd "$COMFYUI_DIR" || exit 1
nohup $PYTHON_BIN ./main.py $BASE_FLAGS $* > "$LOG_FILE" 2>&1 &

echo $! > /tmp/comfyui.pid
echo "✅ ComfyUI successfully restarted with PID $(cat /tmp/comfyui.pid)"
EOF

chmod +x /usr/local/bin/comfyui-restart

# Timeout logic
counter=0
max_wait=100 # safer for cold starts + model init

until curl --silent --fail "$URL" --output /dev/null; do
    if [ $counter -ge $max_wait ]; then
        echo "❌ Timeout: ComfyUI failed to start within ${max_wait}s."
        echo "📋 Check logs: tail -n 100 $NETWORK_VOLUME/comfyui_nohup.log"
        exit 1
    fi

    echo "🔄 ComfyUI Starting... (${counter}s/${max_wait}s)"
    sleep 5
    counter=$((counter + 5))
done

# Final Verification
if curl --silent --fail "$URL" --output /dev/null; then
    echo "🚀 ComfyUI is ready."
fi

echo ""
echo "================================================"
echo ""
echo "  Use the SSH command provided by your host: "
echo ""
echo "  Filebrowser:"
echo ""
echo "     ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8080:localhost:8080"
echo ""
echo "     Then open your browser:"
echo "     http://localhost:8080"
echo ""
echo "  JupyterLab:"
echo ""
echo "     ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8888:localhost:8888"
echo ""
echo "     Then open your browser:"
echo "     http://localhost:8888/lab"
echo ""
echo "  ComfyUI GUI:"
echo ""
echo "     ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8188:localhost:8188"
echo ""
echo "     Then open your browser to:"
echo "     http://localhost:8188"
echo ""
echo "  You can also access JupyterLab via the RunPod web interface if deployed there"
echo ""
echo "================================================"
echo ""

# ============================================================
# SSH Startup
# ============================================================
status_msg "[4/4] 🔐 Starting SSH server..."

mkdir -p /var/run/sshd
chmod 700 /root/.ssh

# If SSH_PUBLIC_KEY provided via env, append safely
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    echo "Adding SSH_PUBLIC_KEY from environment..."
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # Avoid duplicates
    grep -qxF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2> /dev/null \
        || echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
fi

/usr/sbin/sshd

echo "✅ SSH ready."

status_msg "Initialization complete"

# Stream the log to the container output so 'docker logs' works
tail -f "$NETWORK_VOLUME/comfyui_nohup.log" &

sleep infinity
