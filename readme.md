# ComfyUI Wan 2.2 & LTX 2.3 w/ Flash & Sage Attention for CUDA 12.8

## 🛡️ Environment Security & Updates

This heavyweight template is engineered as a self healing container. To prevent runtime dependency drift (e.g., third-party nodes accidentally overwriting the pre-compiled CUDA 12.8 + PyTorch 2.9+ stack or breaking headless OpenCV drivers), the web interface is intentionally locked down.

### 🚫 ComfyUI-Manager is Locked
**Do not attempt to update nodes or install dependencies via the ComfyUI-Manager web GUI.**. Doing so will trigger a `SecurityRestriction` error banner. This is expected behavior designed to protect the container's integrity.

### 🔄 How to Safely Update Nodes
You do not need to update anything manually. This image features a **Smart Boot-Time Synchronizer**:
1. Every time you restart or boot the container, the backend script scans your persistent storage volume.
2. It automatically pulls the latest `git` commits for all your custom nodes.
3. If a node requires new dependencies, the custom compiler intercepts the `requirements.txt`, sanitizes the version pins to match the environment, and updates them safely.

### 📦 How to add other custom nodes:
Method 1: The Drag-and-Drop GUI (Via File Browser)
- Download the custom node repository as a .zip from GitHub to your local desktop.
- Open File Browser at http://localhost:8080.
- Navigate into ComfyUI/custom_nodes/ and drop the zip file right into the window.
- Right-click the uploaded zip file inside File Browser, click Extract
- Navigate to `comfyui-video/src` and execute the script `bash comfyui-sync.sh`

Method 2: The Native Terminal Route (Via SSH)
- Connect to the instance via terminal.
- Run a standard clone command directly inside the volume:
```env
cd ComfyUI/custom_nodes
git clone https://github.com/example/new-custom-node.git
```
- Navigate to `comfyui-video/src` and execute the script `bash comfyui-sync.sh`

### 🔧 Troubleshooting & Live Process Restarts
If ComfyUI crashes due to a hardware Out-of-Memory (OOM) error, or if you want to alter performance configurations
use the live-debugger utility via your SSH terminal:

* **Restart with all active environment configurations intact:**
```bash
comfyui-restart
```
Bypass a specific flag dynamically (e.g., disable FP8 text encoding for testing):
```bash
USE_FP8_TEXT_ENC=false comfyui-restart
```
Append completely custom troubleshooting or memory optimization flags on the fly:
```bash
comfyui-restart --disable-smart-memory --lowvram
```

### Deploy
- RunPod  - https://tinyurl.com/327m5d3t
- Vast.ai - https://tinyurl.com/yv4ncbr4

### Variables Selection

Set the models you want to download to `true`. LTX GGUF is Q8.

```env
DOWNLOAD_LTX23=""
DOWNLOAD_LTX23_GGUF=""
DOWNLOAD_WAN22=""
DOWNLOAD_WAN_ANIMATE=""
DOWNLOAD_WAN_S2V=""
DOWNLOAD_WAN_FUN_CONTROL=""
DOWNLOAD_WAN_CONTROLNETS=""
```

ComfyUI is set to pass the text encoder with fp8 flag by default, if you don't want
that set the following flag to `false`. Optionally you can enable FP8 for the UNET.
```env
USE_FP8_TEXT_ENC=""
USE_FP8_MODEL=""
```
In addition to the Qwen-VL video captioner you have the following other NSFW friendly captioners
JoyCaption Beta One & Florence nsfw v2:
```env
DOWNLOAD_JOYCAPTION=""
DOWNLOAD_FLORENCE2=""
```

This image comes with JupyterLab, Filebrowser and rclone. Specify the password
you want to use for Filebrowser:
```env
FB_PASSWORD=""
```

The Civitai Downloader allows you to download specific models upon deployment by
passing the following variables - to download multiple "438425,567890":
```env
$CHECKPOINT_IDS_TO_DOWNLOAD=""
$LORAS_IDS_TO_DOWNLOAD=""
$BASE_MODEL_IDS_TO_DOWNLOAD=""
$GGUF_IDS_TO_DOWNLOAD=""
```

### Auth Tokens

```env
HUGGINGFACE_API_KEY=""
CIVITAI_TOKEN=""
SSH_PUBLIC_KEY=""
```

##### Note: If you run into bugs, report them to me on discord: bytesizelife

### ⚖️ License & Usage

This project is licensed under AGPL-3.0. Additionally, commercial redistribution — 
including paywalling access to this image or derivative works — is not permitted 
without explicit written permission from the author.

See [LICENSE](LICENSE) for full terms.

### Pre-installed custom nodes:
- ComfyUI-GGUF
- ComfyUI_UltimateSDUpscale
- ComfyUI-KJNodes
- ComfyUI-LivePortraitKJ
- ComfyUI-AnimateDiff-Evolved
- ComfyUI_IPAdapter_plus
- ComfyUI-RIFE-TensorRT-Auto
- ComfyUI-Upscaler-TensorRT-Auto
- ComfyUI-QwenVL-Mod
- ComfyUI-Wan-SVI2Pro-FLF
- ComfyUI-HuggingFace
- rgthree-comfy
- ComfyUI-VideoHelperSuite
- mikey_nodes
- ComfyUI-Impact-Pack
- comfyui_controlnet_aux
- ComfyUI-Easy-Use
- ComfyUI-LatentSyncWrapper
- was-node-suite-comfyui
- ComfyUI-Logic
- ComfyUI_essentials
- cg-image-filter
- ComfyUI-Impact-Subpack
- ComfyUI_LayerStyle
- cg-use-everywhere
- ComfyUI-segment-anything-2
- RES4LYF
- ComfyUI-TeaCache
- ComfyUI-Frame-Interpolation
- ComfyUI-Detail-Daemon
- ComfyUI-WanVideoWrapper
- ComfyUI-WanAnimatePreprocess
- ComfyUI-SCAIL-Pose
- ComfyUI-FSampler
- ComfyUI-WanMoEScheduler
- ComfyUI-VAE-Utils
- ComfyUI-Wan22FMLF
- ComfyUI_LayerStyle_Advance
- ComfyUI-RMBG
- ComfyLiterals
- ComfyUI-Florence2
- ComfyUI-JoyCaption
- 10S-Comfy-nodes
- ComfyUI-LTXVideo

### Ports

| Port | Service     |
|------|-------------|
| 8080 | Filebrowser |
| 8188 | ComfyUI     |
| 8888 | Jupyter     |
| 22   | SSH         |


### Accessing the Instance

If you are using custom SSH key location you might want to create a config file in
`~/.ssh/config` for Linux or `$HOME\.ssh\config` for Windows.

Linux:
```bash
Host *
    IdentityFile PATH/.ssh/id_ed25519
    IdentitiesOnly yes
```
Windows:
```bash 
Host *
    IdentityFile PATH\.ssh\id_ed25519
    IdentitiesOnly yes
```

You can transfer files using `rsync` and connect via SSH
Sync local dataset to remote:
```bash
rsync -avP -e "ssh -p <SSH_PORT>" /path/to/local/dataset/ hostname@<SERVER_IP>:/path/to/remote/dataset/
```

#### Accessing JupyterLab

SSH with port forwarding for JupyterLab
```bash
ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8888:localhost:8888
```
Then open your browser to:
```bash
http://localhost:8888/lab
```

#### Accessing Filebrowser

SSH with port forwarding for Filebrowser
```bash
ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8080:localhost:8080
```
Then open your browser to:
```bash
http://localhost:8080
```

#### Accessing ComfyUI GUI

SSH with port forwarding for ComfyUI
```bash
ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8188:localhost:8188
```
Then open your browser to:
```bash
http://localhost:8188
```
---

### Civitai Downloader

#### 📖 Usage

Download a model using its ID:

```bash
./download_with_aria.py -m 123456

# Download to specific directory
./download_with_aria.py -m 123456 -o ./models

# Use custom filename
./download_with_aria.py -m 123456 --filename "my_custom_model.safetensors"

# Force re-download (ignore existing files)
./download_with_aria.py -m 123456 --force

# Provide token via command line (not recommended for security)
./download_with_aria.py -m 123456 --token "your_token_here"
```

#### Command Line Arguments

| Argument     | Short | Description                          |
|--------------|-------|--------------------------------------|
| `--model-id` | `-m`  | CivitAI model version ID (required)  |
| `--output`   | `-o`  | Output directory                     |
| `--token`    | —     | CivitAI API token                    |
| `--filename` | —     | Override default filename            |
| `--force`    | —     | Force re-download                    |

---

#### 🎯 Examples

**Download a LoRA model:**

```bash
./download_with_aria.py -m 245589

# Download character LoRA
./download_with_aria.py -m 245589 -o ./models/lora/characters

# Download style LoRA
./download_with_aria.py -m 234567 -o ./models/lora/styles

# Download checkpoint
./download_with_aria.py -m 345678 -o ./models/checkpoints
```

**Batch download with a simple script:**

```bash
#!/bin/bash
# download_batch.sh
models=(245589 234567 345678 456789)
for model_id in "${models[@]}"; do
    ./download_with_aria.py -m "$model_id" -o ./models
done
```
