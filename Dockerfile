# Use a single stage to ensure build-tools are available for custom node compilation
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

# Consolidated environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8

# 1. System Dependencies & SSH Setup
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-venv python3-dev python3-pip \
        curl zip unzip ffmpeg ninja-build git aria2 git-lfs wget vim rsync \
        libgl1 libglib2.0-0 libgoogle-perftools4 build-essential libsm6 libxext6 libxrender1 \
        libusb-1.0-0 gcc openssh-server && \
    \
    # Setup Python 3.12 defaults
    ln -sf /usr/bin/python3 /usr/bin/python && \
    ln -sf /usr/bin/pip3 /usr/bin/pip && \
    \
    # Surgical SSH Config
    mkdir -p /root/.ssh /var/run/sshd && \
    chmod 700 /root/.ssh && \
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Stable PyTorch 2.9.1 Stack
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install \
        torch==2.9.1+cu128 \
        torchvision==0.24.1+cu128 \
        torchaudio==2.9.1+cu128 \
        --index-url https://download.pytorch.org/whl/cu128

# 3. Install the build tools first
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install packaging setuptools wheel cython "numpy<2.0" Pillow

# 4. Core Tooling & Critical ML Libraries
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install \
    librosa \
    soundfile \
    decord \
    accelerate \
    transformers \
    diffusers \
    huggingface-hub \
    hf_xet \
    numba \
    psutil \
    peft \
    matplotlib \
    scikit-image \
    scikit-learn \
    mediapipe \
    omegaconf \
    ftfy \
    addict \
    yapf \
    loguru \
    sentencepiece \
    einops \
    scipy \
    timm \
    imageio imageio-ffmpeg "moviepy<2.0" \
    onnxruntime-gpu \
    insightface==0.7.3 \
    triton==3.5.1 \
    gguf \
    bitsandbytes \
    protobuf

# TensorRT for CUDA 12.x (baked in since base image is CUDA 12.8.1)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install \
        tensorrt-cu12==10.13.3.9 \
        tensorrt-cu12-bindings==10.13.3.9 \
        tensorrt-cu12-libs==10.13.3.9 \
        polygraphy \
        cuda-python \
        colored

# 5. Runtime Libraries & Comfy-CLI
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install pyyaml comfy-cli \
        jupyterlab jupyterlab-lsp \
        jupyter-server jupyter-server-terminals ipykernel jupyterlab_code_formatter \
        opencv-contrib-python-headless ultralytics segment-anything transparent-background

RUN curl -fsSL https://rclone.org/install.sh -o /tmp/rclone_install.sh && \
    bash /tmp/rclone_install.sh && \
    rm /tmp/rclone_install.sh

# Establishing workspace
WORKDIR /workspace

# 6. ComfyUI & Custom Nodes (with Directory Fix & CircleCI Heartbeat)
RUN --mount=type=cache,target=/root/.cache/pip \
    # Create workspace and install comfy with analytics disabled
    mkdir -p /ComfyUI/custom_nodes && \
    comfy --workspace /ComfyUI install --non-interactive --yes && \
    set -e; \
    cd /ComfyUI/custom_nodes; \
    for repo in \
        https://github.com/city96/ComfyUI-GGUF.git \
        https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git \
        https://github.com/kijai/ComfyUI-KJNodes.git \
        https://github.com/kijai/ComfyUI-LivePortraitKJ.git \
        https://github.com/ShmuelRonen/ComfyUI_wav2lip.git \
        https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved.git \
        https://github.com/pamparamm/ComfyUI_IPAdapter_plus.git \
        https://github.com/huchukato/ComfyUI-RIFE-TensorRT-Auto.git \
        https://github.com/huchukato/ComfyUI-Upscaler-TensorRT-Auto.git \
        https://github.com/huchukato/ComfyUI-QwenVL-Mod.git \
        https://github.com/Well-Made/ComfyUI-Wan-SVI2Pro-FLF.git \
        https://github.com/huchukato/ComfyUI-HuggingFace.git \
        https://github.com/rgthree/rgthree-comfy.git \
        https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git \
        https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git \
        https://github.com/Jordach/comfy-plasma.git \
        https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
        https://github.com/bash-j/mikey_nodes.git \
        https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
        https://github.com/Fannovel16/comfyui_controlnet_aux.git \
        https://github.com/yolain/ComfyUI-Easy-Use.git \
        https://github.com/kijai/ComfyUI-Florence2.git \
        https://github.com/ShmuelRonen/ComfyUI-LatentSyncWrapper.git \
        https://github.com/ltdrdata/was-node-suite-comfyui.git \
        https://github.com/theUpsider/ComfyUI-Logic.git \
        https://github.com/cubiq/ComfyUI_essentials.git \
        https://github.com/chrisgoringe/cg-image-filter.git \
        https://github.com/chflame163/ComfyUI_LayerStyle.git \
        https://github.com/chrisgoringe/cg-use-everywhere.git \
        https://github.com/kijai/ComfyUI-segment-anything-2.git \
        https://github.com/ClownsharkBatwing/RES4LYF \
        https://github.com/welltop-cn/ComfyUI-TeaCache.git \
        https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git \
        https://github.com/Jonseed/ComfyUI-Detail-Daemon.git \
        https://github.com/kijai/ComfyUI-WanVideoWrapper.git \
        https://github.com/wildminder/ComfyUI-VibeVoice.git \
        https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git \
        https://github.com/obisin/ComfyUI-FSampler.git \
        https://github.com/cmeka/ComfyUI-WanMoEScheduler.git \
        https://github.com/lrzjason/ComfyUI-VAE-Utils.git \
        https://github.com/wallen0322/ComfyUI-Wan22FMLF.git \
        https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git \
        https://github.com/BadCafeCode/masquerade-nodes-comfyui.git \
        https://github.com/1038lab/ComfyUI-RMBG.git \
        https://github.com/M1kep/ComfyLiterals.git; \
    do \
        repo_dir=$(basename "$repo" .git); \
        echo "CIRCLECI_HEARTBEAT: Installing $repo_dir into $(pwd)..."; \
        \
        # Clone with depth 1
        if [ "$repo" = "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git" ]; then \
            git clone --depth 1 --recursive "$repo"; \
        else \
            git clone --depth 1 "$repo"; \
        fi; \
        \
        # ComfyUI-Frame-Interpolation sed patch
        if [ "$repo_dir" = "ComfyUI-Frame-Interpolation" ]; then \
            if [ -f "$repo_dir/requirements-with-cupy.txt" ]; then \
                echo "🛠️ Harmonizing ComfyUI-Frame-Interpolation cupy requirements..."; \
                sed -i -E 's/opencv-(python|contrib-python)(-headless)?(\[[a-zA-Z0-9_-]+\])?(==[0-9.]+)?/opencv-contrib-python-headless/g' "$repo_dir/requirements-with-cupy.txt"; \
                sed -i -E 's/^torch([>=<~= ]+[0-9.]+)?$/# torch already installed/g' "$repo_dir/requirements-with-cupy.txt"; \
                sed -i -E 's/^torchvision([>=<~= ]+[0-9.]+)?$/# torchvision already installed/g' "$repo_dir/requirements-with-cupy.txt"; \
                sed -i -E 's/^numpy([>=<~= ]+[0-9.]+)?$/# numpy already installed/g' "$repo_dir/requirements-with-cupy.txt"; \
                sed -i -E 's/^Pillow([>=<~= ]+[0-9.]+)?$/# Pillow already installed/g' "$repo_dir/requirements-with-cupy.txt"; \
                sed -i -E 's/^cupy-wheel$/cupy-cuda12x/g' "$repo_dir/requirements-with-cupy.txt"; \
            fi; \
        fi; \
        \
        # 4. Harmonize and Install Requirements
        if [ -f "$repo_dir/requirements.txt" ]; then \
            echo "🛠️ Harmonizing Dependencies for $repo_dir..."; \
            \
            # 1. Harmonize OpenCV
            sed -i -E 's/opencv-(python|contrib-python)(-headless)?(\[[a-zA-Z0-9_-]+\])?(==[0-9.]+)?/opencv-contrib-python-headless/g' "$repo_dir/requirements.txt"; \
            \
            # 2. Harmonize bitsandbytes (Strips versions like ==0.41.1 or >=0.35)
            sed -i -E 's/bitsandbytes([>=<~= ]+[0-9.]+)?/bitsandbytes/g' "$repo_dir/requirements.txt"; \
            \
            # 3. Harmonize protobuf
            sed -i -E 's/protobuf([>=<~= ]+[0-9.]+)?/protobuf/g' "$repo_dir/requirements.txt"; \
            \
            # 4. Harmonize onnxruntime
            sed -i -E 's/^onnxruntime([>=<~= ]+[0-9.]+)?$/onnxruntime-gpu/g' "$repo_dir/requirements.txt"; \
            \
            # 5. Strip torch stack (already installed with specific CUDA build)
            sed -i -E 's/^torch([>=<~= ]+[0-9.]+)?$/# torch already installed/g' "$repo_dir/requirements.txt"; \
            \
            sed -i -E 's/^torchvision([>=<~= ]+[0-9.]+)?$/# torchvision already installed/g' "$repo_dir/requirements.txt"; \
            \
            sed -i -E 's/^torchaudio([>=<~= ]+[0-9.]+)?$/# torchaudio already installed/g' "$repo_dir/requirements.txt"; \
            \
            # 6. Strip numpy (already pinned to <2.0)
            sed -i -E 's/^numpy([>=<~= ]+[0-9.]+)?$/# numpy already installed/g' "$repo_dir/requirements.txt"; \
            \
            # 7. Strip numba version pin (managed globally to stay compatible with numpy)
            sed -i -E 's/^numba([>=<~= ]+[0-9.]+)?$/numba/g' "$repo_dir/requirements.txt"; \
            \
            # 8. Strip clip-interrogator
            sed -i -E 's/^clip[-_]interrogator([>=<~= ]+[0-9.]+)?$/clip-interrogator/g' "$repo_dir/requirements.txt"; \
            \
            pip install --progress-bar off -v -r "$repo_dir/requirements.txt"; \
        fi; \
        \
        # 5. Run install.py if it exists
        if [ -f "$repo_dir/install.py" ]; then \
            python "$repo_dir/install.py"; \
        fi; \
    done

# 7. Final Assets & Entrypoint
COPY src/start_script.sh /start_script.sh
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY 4xLSDIR.pth /4xLSDIR.pth

RUN chmod +x /start_script.sh /docker-entrypoint.sh

# Fix for JoyCaption / Protobuf compatibility
ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/start_script.sh"]