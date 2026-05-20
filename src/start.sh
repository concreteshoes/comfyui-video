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

# ---------------------------------------------------------
# Flash Attention 2.8.3
# ---------------------------------------------------------
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
                python setup.py install
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

# ---------------------------------------------------------
# Sage Attention 2.x
# ---------------------------------------------------------
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
# This is in case there's any special installs or overrides that needs to occur when starting the machine before starting ComfyUI
if [ -f "$NETWORK_VOLUME/comfyui-wan/src/additional_params.sh" ]; then
    chmod +x "$NETWORK_VOLUME/comfyui-wan/src/additional_params.sh"
    echo "Executing additional_params.sh..."
    "$NETWORK_VOLUME/comfyui-wan/src/additional_params.sh"
else
    echo "No additional_params.sh found. Skipping..."
fi

if ! which aria2 > /dev/null 2>&1; then
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
else
    echo "aria2 is already installed"
fi

if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

echo "Starting JupyterLab in $NETWORK_VOLUME"
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser \
    --NotebookApp.token='' --NotebookApp.password='' \
    --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True \
    --notebook-dir="$NETWORK_VOLUME" &

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
mkdir -p "$CUSTOM_NODES_DIR"

if [ ! -d "$COMFYUI_DIR" ]; then
    status_msg "First Boot: Moving ComfyUI to Volume..."
    mv /ComfyUI "$COMFYUI_DIR"
else
    status_msg "Restart detected: Syncing latest Image changes to Volume..."
    # Using . ensures hidden files are included, and -T treats destination as a directory
    cp -ruvT /ComfyUI "$COMFYUI_DIR"
    rm -rf /ComfyUI
    echo "✅ Sync complete."
fi

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

# SMART SYNC: Update all existing nodes automatically
echo "🔄 Checking for updates and new dependencies..."
find "$CUSTOM_NODES_DIR" -maxdepth 1 -type d -not -path "$CUSTOM_NODES_DIR" | while read -r node_path; do
    if [ -d "$node_path/.git" ]; then
        node_name=$(basename "$node_path")

        # Check the 'mtime' (modified time) of requirements.txt before pulling
        REQ_FILE="$node_path/requirements.txt"
        BEFORE_MOD=0
        [ -f "$REQ_FILE" ] && BEFORE_MOD=$(stat -c %Y "$REQ_FILE" 2> /dev/null || stat -f %m "$REQ_FILE" 2> /dev/null)

        # Perform the update
        (cd "$node_path" && git pull --ff-only -q > /dev/null 2>&1)

        # Check if requirements.txt exists and if it was updated
        if [ -f "$REQ_FILE" ]; then
            AFTER_MOD=$(stat -c %Y "$REQ_FILE" 2> /dev/null || stat -f %m "$REQ_FILE" 2> /dev/null)

            if [ "$BEFORE_MOD" != "$AFTER_MOD" ]; then
                echo "📦 New dependencies detected for $node_name. Installing..."
                # Use --no-cache-dir to save space on your volume
                $PYTHON_BIN -m pip install --no-cache-dir -r "$REQ_FILE" > /dev/null 2>&1
            fi
        fi
    fi
done
echo "✅ All nodes updated and dependencies verified."

# VERSION LOCKS: Pin specific nodes that break when updated
if [ -d "$CUSTOM_NODES_DIR/ComfyUI-KJNodes" ]; then
    echo "📌 Pinning KJNodes to stable commit 204f6d5..."
    (cd "$CUSTOM_NODES_DIR/ComfyUI-KJNodes" && git reset --hard 204f6d5 > /dev/null 2>&1)
fi

echo "🔧 Installing requirements for core Wan nodes in background..."
if [ -f "$CUSTOM_NODES_DIR/ComfyUI-KJNodes/requirements.txt" ]; then
    (
        $PYTHON_BIN -m pip install --no-cache-dir \
            -r "$CUSTOM_NODES_DIR/ComfyUI-KJNodes/requirements.txt"
    ) &
    WAN_REQS_PID=$!
else
    echo "⚠️ KJNodes requirements not found, skipping background install."
    WAN_REQS_PID=""
fi

export CHANGE_PREVIEW_METHOD="true"

# Change to the directory
cd "$CUSTOM_NODES_DIR" || exit 1

# Function to download a model using huggingface-cli
download_model() {
    local url="$1"
    local full_path="$2"

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # Simple corruption check: file < 10MB or .aria2 files
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2> /dev/null || stat -c%s "$full_path" 2> /dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))

        if [ "$size_bytes" -lt 10485760 ]; then # Less than 10MB
            echo "🗑️  Deleting corrupted file (${size_mb}MB < 10MB): $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists (${size_mb}MB), skipping download."
            return 0
        fi
    fi

    # Check for and remove .aria2 control files
    if [ -f "${full_path}.aria2" ]; then
        echo "🗑️  Deleting .aria2 control file: ${full_path}.aria2"
        rm -f "${full_path}.aria2"
        rm -f "$full_path" # Also remove any partial file
    fi

    echo "📥 Downloading $destination_file to $destination_dir..."

    # Download without falloc (since it's not supported in your environment)
    aria2c -x 16 -s 16 -k 1M --continue=true --file-allocation=none -d "$destination_dir" -o "$destination_file" "$url" &

    echo "Download started in background for $destination_file"
}

# Define base paths
DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
CLIP_VISION_DIR="$NETWORK_VOLUME/ComfyUI/models/clip_vision"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"
LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"
DETECTION_DIR="$NETWORK_VOLUME/ComfyUI/models/detection"
AUDIO_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/audio_encoders"
LATENTSYNC_DIR="$NETWORK_VOLUME/ComfyUI/models/checkpoints/latentsync"
CIVITAI_GGUF="$NETWORK_VOLUME/ComfyUI/models/unet"
LIVEPORTRAIT_DIR="$NETWORK_VOLUME/ComfyUI/models/liveportrait"
INSIGHTFACE_DIR="$NETWORK_VOLUME/ComfyUI/models/antelopev2"
ANIMATEDIFF_DIR="NETWORK_VOLUME/ComfyUI/models/animatediff_models"
MOTION_LORA_DIR="$NETWORK_VOLUME/ComfyUI/models/animatediff_motion_lora"
IPADAPTER_DIR="$NETWORK_VOLUME/ComfyUI/models/ipadapter"
JOYCAPTION_DIR="$NETWORK_VOLUME/ComfyUI/models/LLavacheckpoints/llama-joycaption-beta-one-hf-llava"
FLORENCE2_DIR="$NETWORK_VOLUME/ComfyUI/models/florence2/base-PromptGen"

# ==========================================
# WAN 2.1
# ==========================================
# Download 480p native models
if [ "${DOWNLOAD_480P_NATIVE_MODELS:-}" = "true" ]; then
    echo "📥 Downloading 480p native models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_480p_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
fi

# Handle full download (with SDXL)
if [ "${DOWNLOAD_WAN_FUN_AND_SDXL_HELPER:-}" = "true" ]; then
    echo "📥 Downloading Wan Fun 14B model..."

    download_model "https://huggingface.co/alibaba-pai/Wan2.1-Fun-14B-Control/resolve/main/diffusion_pytorch_model.safetensors" "$DIFFUSION_MODELS_DIR/diffusion_pytorch_model.safetensors"

    UNION_DIR="$NETWORK_VOLUME/ComfyUI/models/controlnet/SDXL/controlnet-union-sdxl-1.0"
    mkdir -p "$UNION_DIR"
    if [ ! -f "$UNION_DIR/diffusion_pytorch_model_promax.safetensors" ]; then
        download_model "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors" "$UNION_DIR/diffusion_pytorch_model_promax.safetensors"
    fi
fi

if [ "${DOWNLOAD_VACE:-}" = "true" ]; then
    echo "📥 Downloading VACE 14B Model"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_1-VACE_module_14B_bf16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_1_3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_1-VACE_module_1_3B_bf16.safetensors"
fi

# Download 720p native models
if [ "${DOWNLOAD_720P_NATIVE_MODELS:-}" = "true" ]; then
    echo "📥 Downloading 720p native models..."

    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_720p_14B_bf16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
fi

# Download Steady Dancer model
if [ "${DOWNLOAD_STEADY_DANCER:-}" = "true" ]; then
    echo "📥 Downloading Steady Dancer..."

    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/SteadyDancer/Wan21_I2V_SteadyDancer_fp16.safetensors" "$DIFFUSION_MODELS_DIR/Wan21_I2V_SteadyDancer_fp16.safetensors"
fi

if [ "${DOWNLOAD_INFINITETALK:-true}" = "true" ]; then
    echo "📥 Downloading InfiniteTalk..."
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_1-InfiniTetalk-Single_fp16.safetensors"
fi

# ==========================================
# WAN 2.2
# ==========================================
# Download Wan 2.2 model by default
if [ "${DOWNLOAD_WAN22:-true}" = "true" ]; then
    echo "📥 Downloading Wan 2.2"

    download_model "https://huggingface.co/MonsterMMORPG/Wan_GGUF/resolve/main/Wan-2.2-T2V-High-Noise-BF16.safetensors" "$DIFFUSION_MODELS_DIR/Wan-2.2-T2V-High-Noise-BF16.safetensors"

    download_model "https://huggingface.co/MonsterMMORPG/Wan_GGUF/resolve/main/Wan-2.2-T2V-Low-Noise-BF16.safetensors" "$DIFFUSION_MODELS_DIR/Wan-2.2-T2V-Low-Noise-BF16.safetensors"

    download_model "https://huggingface.co/MonsterMMORPG/Wan_GGUF/resolve/main/Wan-2.2-I2V-High-Noise-BF16.safetensors" "$DIFFUSION_MODELS_DIR/Wan-2.2-I2V-High-Noise-BF16.safetensors"

    download_model "https://huggingface.co/MonsterMMORPG/Wan_GGUF/resolve/main/Wan-2.2-I2V-Low-Noise-BF16.safetensors" "$DIFFUSION_MODELS_DIR/Wan-2.2-I2V-Low-Noise-BF16.safetensors"
fi

# Download Wan Animate model by default
if [ "${DOWNLOAD_WAN_ANIMATE:-true}" = "true" ]; then
    echo "📥 Downloading Wan Animate model..."

    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_animate_14B_bf16.safetensors"

    # Download detection models for WanAnimatePreprocess
    echo "Downloading detection models..."
    download_model "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" "$DETECTION_DIR/yolov10m.onnx"
    download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" "$DETECTION_DIR/vitpose_h_wholebody_data.bin"
    download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" "$DETECTION_DIR/vitpose_h_wholebody_model.onnx"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_animate_14B_relight_lora_bf16.safetensors" "$LORAS_DIR/wan2.2_animate_14B_relight_lora_bf16.safetensors"
fi

if [ "${DOWNLOAD_WAN_S2V:-true}" = "true" ]; then
    echo "📥 Downloading Wan 2.2 S2V models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_s2v_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_s2v_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/audio_encoders/wav2vec2_large_english_fp16.safetensors" "$AUDIO_ENCODERS_DIR/wav2vec2_large_english_fp16.safetensors"
fi

# ==========================================
# OPTIMIZATION LORAS
# ==========================================
echo "📥 Downloading optimization loras"
if [ "${DOWNLOAD_720P_NATIVE_MODELS:-}" = "true" ] || [ "${DOWNLOAD_480P_NATIVE_MODELS:-}" = "true" ]; then
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_CausVid_14B_T2V_lora_rank32.safetensors" "$LORAS_DIR/Wan21_CausVid_14B_T2V_lora_rank32.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors" "$LORAS_DIR/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" "$LORAS_DIR/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
fi

if [ "${DOWNLOAD_WAN22:-}" = "true" ]; then
    download_model "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/high_noise_model.safetensors" "$LORAS_DIR/t2v_lightx2v_high_noise_model.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors" "$LORAS_DIR/t2v_lightx2v_low_noise_model.safetensors"
    #
    download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors" "$LORAS_DIR/i2v_lightx2v_high_noise_model.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors" "$LORAS_DIR/i2v_lightx2v_low_noise_model.safetensors"
    #
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_260412_rank_64_fp16.safetensors" "$LORAS_DIR/Wan_2_2_I2V_A14B_HIGH_lightx2v_4step_lora_260412_rank_64_fp16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_Lightx2v/Wan_2_2_I2V_A14B_LOW_lightx2v_4step_lora_260412_rank_64_fp16.safetensors" "$LORAS_DIR/Wan_2_2_I2V_A14B_LOW_lightx2v_4step_lora_260412_rank_64_fp16.safetensors"
    #
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors" "$LORAS_DIR/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors" "$LORAS_DIR/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors"
    #
    download_model "https://civitai.red/api/download/models/2609141?type=Model&format=SafeTensor&size=full&fp=fp16" "$DIFFUSION_MODELS_DIR/wan22EnhancedNSFWSVICamera_nolightningSVICfFp8H.safetensors"
    download_model "https://civitai.red/api/download/models/2609148?type=Model&format=SafeTensor&size=full&fp=fp8" "$DIFFUSION_MODELS_DIR/wan22EnhancedNSFWSVICamera_nolightningSVICfFp8L.safetensors"
fi

# ==========================================
# TEXT ENCODERS
# ==========================================

# Download text encoders
echo "📥 Downloading text encoders..."
download_model "https://huggingface.co/zootkitty/nsfw_wan_umt5-xxl_bf16_fixed/resolve/main/nsfw_wan_umt5-xxl_bf16_fixed.safetensors" "$TEXT_ENCODERS_DIR/nsfw_wan_umt5-xxl_bf16_fixed.safetensors"

download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" "$TEXT_ENCODERS_DIR/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors"

download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$CLIP_VISION_DIR/clip_vision_h.safetensors"

# ==========================================
# VAE
# ==========================================

# Download VAE
if [ "${DOWNLOAD_VACE:-}" = "true" ] || [ "${DOWNLOAD_720P_NATIVE_MODELS:-}" = "true" ] || [ "${DOWNLOAD_480P_NATIVE_MODELS:-}" = "true" ] || [ "${DOWNLOAD_WAN_S2V:-true}" = "true" ]; then
    echo "📥 Downloading VAE..."
    download_model "https://huggingface.co/MonsterMMORPG/Wan_GGUF/resolve/main/Wan2_1_VAE_bf16.safetensors" "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
fi

# ==========================================
# JOYCAPTION BETA ONE
# ==========================================
if [ "${DOWNLOAD_JOYCAPTION:-}" = "true" ]; then
    echo "📥 Downloading JoyCaption Beta One..."

    # 1. Config & Tokenizer Files
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/config.json" "$JOYCAPTION_DIR/config.json"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/generation_config.json" "$JOYCAPTION_DIR/generation_config.json"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model.safetensors.index.json" "$JOYCAPTION_DIR/model.safetensors.index.json"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/preprocessor_config.json" "$JOYCAPTION_DIR/preprocessor_config.json"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/special_tokens_map.json" "$JOYCAPTION_DIR/special_tokens_map.json"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/tokenizer.json" "$JOYCAPTION_DIR/tokenizer.json"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/tokenizer_config.json" "$JOYCAPTION_DIR/tokenizer_config.json"

    # 2. Sharded Weights
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model-00001-of-00004.safetensors" "$JOYCAPTION_DIR/model-00001-of-00004.safetensors"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model-00002-of-00004.safetensors" "$JOYCAPTION_DIR/model-00002-of-00004.safetensors"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model-00003-of-00004.safetensors" "$JOYCAPTION_DIR/model-00003-of-00004.safetensors"
    download_model "https://huggingface.co/fancyfeast/llama-joycaption-beta-one-hf-llava/resolve/main/model-00004-of-00004.safetensors" "$JOYCAPTION_DIR/model-00004-of-00004.safetensors"

    echo "✅ JoyCaption Beta One model downloads scheduled"
fi

# ==========================================
# FLORENCE-2 NSFW V2
# ==========================================
if [ "${DOWNLOAD_FLORENCE2:-}" = "true" ]; then
    echo "📥 Downloading Florence-2 NSFW finetune..."

    # Base URL for the finetune
    NSFW_BASE_URL="https://huggingface.co/ljnlonoljpiljm/florence-2-base-nsfw-v2/resolve/main"

    # 1. Core Configuration & Tokenizer
    download_model "$NSFW_BASE_URL/config.json" "$FLORENCE2_DIR/config.json"
    download_model "$NSFW_BASE_URL/generation_config.json" "$FLORENCE2_DIR/generation_config.json"
    download_model "$NSFW_BASE_URL/preprocessor_config.json" "$FLORENCE2_DIR/preprocessor_config.json"
    download_model "$NSFW_BASE_URL/added_tokens.json" "$FLORENCE2_DIR/added_tokens.json"
    download_model "$NSFW_BASE_URL/merges.txt" "$FLORENCE2_DIR/merges.txt"
    download_model "$NSFW_BASE_URL/special_tokens_map.json" "$FLORENCE2_DIR/special_tokens_map.json"
    download_model "$NSFW_BASE_URL/tokenizer.json" "$FLORENCE2_DIR/tokenizer.json"
    download_model "$NSFW_BASE_URL/tokenizer_config.json" "$FLORENCE2_DIR/tokenizer_config.json"
    download_model "$NSFW_BASE_URL/vocab.json" "$FLORENCE2_DIR/vocab.json"

    # 2. The Weights
    download_model "$NSFW_BASE_URL/model.safetensors" "$FLORENCE2_DIR/model.safetensors"

    # 3. Microsoft Processor (Handles the actual image bounding boxes/cropping)
    download_model "https://huggingface.co/microsoft/Florence-2-base/resolve/main/processing_florence2.py" "$FLORENCE2_DIR/processing_florence2.py"

    # 4. APPLY THE KIJAI / LAYERSTYLE PATCH
    # We copy the patched modeling and config files directly from the custom node directory
    # to overwrite any missing or outdated files, ensuring transformers >= 4.45 compatibility.
    echo "🔧 Applying Transformers compatibility patch for Florence-2..."
    LAYERSTYLE_MODELS_DIR="/ComfyUI/custom_nodes/ComfyUI_LayerStyle_Advance/florence2_models"

    if [ -d "$LAYERSTYLE_MODELS_DIR" ]; then
        cp "$LAYERSTYLE_MODELS_DIR/modeling_florence2.py" "$FLORENCE2_DIR/"
        cp "$LAYERSTYLE_MODELS_DIR/configuration_florence2.py" "$FLORENCE2_DIR/"
        echo "✅ Florence-2 patched successfully."
    else
        echo "⚠️ WARNING: LayerStyle advance folder not found at $LAYERSTYLE_MODELS_DIR. Patch skipped."
    fi

    echo "✅ Florence-2 NSFW scheduled"
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
download_model "https://huggingface.co/ByteDance/LatentSync/resolve/main/vae/config.json" "$LATENTSYNC_DIR/vae/config.json"
download_model "https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors" "$LATENTSYNC_DIR/vae/diffusion_pytorch_model.safetensors"

# ==========================================
# INSIGHTFACE
# ==========================================
echo "📥 Downloading InsightFace weights..."
# Download the AntelopeV2 model pack (standard for high-quality detection)
# These are the 5 core files needed for InsightFace to 'see' the face
download_model "https://huggingface.co/comfyanonymous/models/resolve/main/insightface/models/antelopev2/1080_720.onnx" "$INSIGHTFACE_DIR/1080_720.onnx"
download_model "https://huggingface.co/comfyanonymous/models/resolve/main/insightface/models/antelopev2/2d106det.onnx" "$INSIGHTFACE_DIR/2d106det.onnx"
download_model "https://huggingface.co/comfyanonymous/models/resolve/main/insightface/models/antelopev2/3d68tk7.onnx" "$INSIGHTFACE_DIR/3d68tk7.onnx"
download_model "https://huggingface.co/comfyanonymous/models/resolve/main/insightface/models/antelopev2/genderage.onnx" "$INSIGHTFACE_DIR/genderage.onnx"
download_model "https://huggingface.co/comfyanonymous/models/resolve/main/insightface/models/antelopev2/scrfd_10g_bnkps.onnx" "$INSIGHTFACE_DIR/scrfd_10g_bnkps.onnx"

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

# Many of Kijai's 'Expression' nodes prefer Buffalo_L over AntelopeV2
mkdir -p "$NETWORK_VOLUME/ComfyUI/models/insightface/models/buffalo_l"
download_model "https://huggingface.co/deepinsight/insightface/resolve/main/models/buffalo_l.zip" "$NETWORK_VOLUME/ComfyUI/models/insightface/models/buffalo_l.zip"
unzip -o "$NETWORK_VOLUME/ComfyUI/models/insightface/models/buffalo_l.zip" -d "$INSIGHTFACE_MODELS_DIR"

# Clean up the zip to save space on your network volume
rm "$NETWORK_VOLUME/ComfyUI/models/insightface/models/buffalo_l.zip"

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
# IPADAPTER PLUS
# ==========================================
# CLIP Vision (The Image Encoder)
# This is the standard ViT-H model required by almost all IPAdapters
download_model "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" "$CLIP_VISION_DIR/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"

# IPAdapter Face Models (For Character Consistency)
# SD 1.5 Face Plus (Great for fast AnimateDiff face consistency)
download_model "https://huggingface.co/h94/IP-Adapter/resolve/main/models/ip-adapter-plus-face_sd15.safetensors" "$IPADAPTER_DIR/ip-adapter-plus-face_sd15.safetensors"

# SDXL Face Plus (Great for high-res base images before Wan I2V)
download_model "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus-face_sdxl_vit-h.safetensors" "$IPADAPTER_DIR/ip-adapter-plus-face_sdxl_vit-h.safetensors"

# Keep checking until no aria2c processes are running
if pgrep -x "aria2c" > /dev/null; then
    echo "⏳ Waiting for downloads..."
    while pgrep -x "aria2c" > /dev/null; do
        sleep 5
    done
fi

declare -A MODEL_CATEGORIES=(
    ["$NETWORK_VOLUME/ComfyUI/models/checkpoints"]="$CHECKPOINT_IDS_TO_DOWNLOAD"
    ["$NETWORK_VOLUME/ComfyUI/models/loras"]="$LORAS_IDS_TO_DOWNLOAD"
)

# Counter to track background jobs
download_count=0

# Ensure directories exist and schedule downloads in background
for TARGET_DIR in "${!MODEL_CATEGORIES[@]}"; do
    mkdir -p "$TARGET_DIR"
    MODEL_IDS_STRING="${MODEL_CATEGORIES[$TARGET_DIR]}"

    # Skip if the value is the default placeholder
    if [[ "$MODEL_IDS_STRING" == "replace_with_ids" ]]; then
        echo "⏭️  Skipping downloads for $TARGET_DIR (default value detected)"
        continue
    fi

    IFS=',' read -ra MODEL_IDS <<< "$MODEL_IDS_STRING"

    for MODEL_ID in "${MODEL_IDS[@]}"; do
        sleep 1
        echo "🚀 Scheduling download: $MODEL_ID to $TARGET_DIR"
        (cd "$TARGET_DIR" && download_with_aria.py -m "$MODEL_ID") &
        ((download_count++))
    done
done

echo "📋 Scheduled $download_count downloads in background"

# Wait for all downloads to complete
if pgrep -x "aria2c" > /dev/null; then
    echo "⏳ Waiting for downloads..."
    while pgrep -x "aria2c" > /dev/null; do
        sleep 5
    done
fi

echo "✅ All models downloaded successfully!"

echo "All downloads completed!"

echo "Downloading upscale models"
mkdir -p "$NETWORK_VOLUME/ComfyUI/models/upscale_models"
if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/upscale_models/4xLSDIR.pth" ]; then
    if [ -f "/4xLSDIR.pth" ]; then
        mv "/4xLSDIR.pth" "$NETWORK_VOLUME/ComfyUI/models/upscale_models/4xLSDIR.pth"
        echo "Moved 4xLSDIR.pth to the correct location."
    else
        echo "4xLSDIR.pth not found in the root directory."
    fi
else
    echo "4xLSDIR.pth already exists. Skipping."
fi

echo "Finished downloading models!"

echo "Checking and copying workflow..."
mkdir -p "$WORKFLOW_DIR"

# Ensure the file exists in the current directory before moving it
cd /

SOURCE_DIR="/comfyui-wan/workflows"

# Loop over each subdirectory in the source directory
for dir in "$SOURCE_DIR"/*/; do
    # Skip if no directories match (empty glob)
    [[ -d "$dir" ]] || continue

    dir_name="$(basename "$dir")"
    dest_dir="$WORKFLOW_DIR/$dir_name"

    if [[ -e "$dest_dir" ]]; then
        echo "Directory already exists in destination. Deleting source: $dir"
        rm -rf "$dir"
    else
        echo "Moving: $dir to $WORKFLOW_DIR"
        mv "$dir" "$WORKFLOW_DIR/"
    fi
done

if [ "${CHANGE_PREVIEW_METHOD:-false}" = "true" ]; then
    echo "Updating default preview method..."
    VHS_JS_FILE="$NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/web/js/VHS.core.js"

    if [ -f "$VHS_JS_FILE" ]; then
        sed -i '/id: *'"'"'VHS.LatentPreview'"'"'/,/defaultValue:/s/defaultValue: false/defaultValue: true/' "$VHS_JS_FILE"
        echo "Default preview method updated to 'auto'"
    else
        echo "⚠️ VHS.core.js not found. Skipping preview method update."
    fi
    CONFIG_PATH="$COMFYUI_DIR/user/default/ComfyUI-Manager"
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
share_option = all
bypass_ssl = False
file_logging = True
component_policy = workflow
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = normal
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
else
    echo "Skipping preview method update (CHANGE_PREVIEW_METHOD is not 'true')."
fi

# Workspace as main working directory
echo "cd $NETWORK_VOLUME" >> ~/.bashrc

# Install dependencies
echo "⏳ Waiting for background dependency installs to finish..."
if [ -n "$WAN_REQS_PID" ]; then
    wait $WAN_REQS_PID
    REQ_STATUS=$?
else
    REQ_STATUS=0
fi

if [ $REQ_STATUS -ne 0 ]; then
    echo "❌ Core Wan node requirements failed to install."
else
    echo "✅ All Wan dependencies installed successfully."
fi

status_msg "Checking for ZIP-masked LoRAs..."
cd "$LORAS_DIR" || echo "LoRA dir not found, skipping rename."
# The 'nullglob' prevents the loop from running if no .zip files exist
shopt -s nullglob
for file in *.zip; do
    echo "📦 Unmasking $file to .safetensors"
    mv "$file" "${file%.zip}.safetensors"
done
shopt -u nullglob

# Return to the ComfyUI root directory before launching
cd "$NETWORK_VOLUME/ComfyUI" || exit 1

# GPU VRAM check
# Grabs the total memory of the first GPU in MB
GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
VRAM_THRESHOLD=32000 # 32GB in MB

echo "📟 Detected GPU VRAM: ${GPU_VRAM_MB}MB"

# Build Command
LAUNCH_FLAGS="--listen --preview-method auto"

# Add FP8 flags if enabled
if [ "${USE_FP8_TEXT_ENC:-true}" = "true" ]; then
    LAUNCH_FLAGS="$LAUNCH_FLAGS --fp8_e4m3fn-text-enc"
    status_msg "FP8 text encoder enabled"
fi

if [ "${USE_FP8_MODEL:-}" = "true" ]; then
    LAUNCH_FLAGS="$LAUNCH_FLAGS --fp8_e4m3fn-unet"
    status_msg "FP8 model weight casting enabled (E4M3FN)"
fi

# Memory Optimization based on VRAM
if [ "$GPU_VRAM_MB" -ge "$VRAM_THRESHOLD" ]; then
    echo "🚀 High VRAM detected (32GB+). Enabling --highvram."
    LAUNCH_FLAGS="$LAUNCH_FLAGS --highvram"
else
    echo "⚖️ Standard VRAM detected."
    # ComfyUI natively uses --weight-dtype to force model precision
    LAUNCH_FLAGS="$LAUNCH_FLAGS --medvram"
fi

# SageAttention check
if [ "$SAGE_ATTENTION_AVAILABLE" = "true" ]; then
    echo "✨ SageAttention enabled."
    LAUNCH_FLAGS="$LAUNCH_FLAGS --use-sage-attention"
fi

COMFYUI_CMD="$PYTHON_BIN $COMFYUI_DIR/main.py $LAUNCH_FLAGS"

# Runtime Updates (Added 'install' keyword)
echo "🆙 Updating runtime extensions..."
$PYTHON_BIN -m pip install --no-cache-dir comfy-aimdo comfy-kitchen --upgrade

# Launch
URL="http://127.0.0.1:8188"
status_msg "▶️ Starting ComfyUI with flags: $LAUNCH_FLAGS"
nohup $COMFYUI_CMD > "$NETWORK_VOLUME/comfyui_nohup.log" 2>&1 &
echo $! > /tmp/comfyui.pid # Save PID for restart

# Debugging mode
cat > /usr/local/bin/comfyui-restart << 'EOF'
#!/bin/bash

PYTHON_BIN="/usr/bin/python3"
COMFYUI_DIR="${NETWORK_VOLUME:-/workspace}/ComfyUI"
LOG_FILE="${NETWORK_VOLUME:-/workspace}/comfyui_nohup.log"

echo "Stopping ComfyUI..."
kill $(cat /tmp/comfyui.pid 2>/dev/null) 2>/dev/null
sleep 2

echo "Relaunching with debug flags..."
BASE_FLAGS="--listen --preview-method auto --use-sage-attention"

echo "Base flags: $BASE_FLAGS"
echo "Extra flags: $@"

nohup $PYTHON_BIN $COMFYUI_DIR/main.py \
    $BASE_FLAGS $@ \
    > "$LOG_FILE" 2>&1 &

echo $! > /tmp/comfyui.pid
echo "ComfyUI restarted PID $(cat /tmp/comfyui.pid)"
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
echo "  Template ready!"
echo ""
echo "  To access JupyterLab from your local machine:"
echo ""
echo "  1) Use the SSH command provided by your host (Vast.ai / RunPod),"
echo "     and add port forwarding like this:"
echo ""
echo "     ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8888:localhost:8888"
echo ""
echo "  2) Then open your browser:"
echo "     http://localhost:8888/lab"
echo ""
echo "  To access ComfyUI GUI on port 8188:"
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

# ================================
# SSH Startup
# ================================

echo "🔐 Starting SSH server..."

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
