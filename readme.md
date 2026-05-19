# ComfyUI Wan w/ Sage Attention for CUDA 12.8

### Deploy
- RunPod  - https://tinyurl.com/ynfwwzxu
- Vast.ai - https://tinyurl.com/28jvbeuv

### Variables Selection

Both Wan 2.2, Animate, S2V and Wan 2.1 InfiniteTalk are always set to download, use `false` to disable.
Other models are skipped unless set to `true`.

```env
DOWNLOAD_WAN22=""
DOWNLOAD_WAN_ANIMATE=""
DOWNLOAD_WAN_S2V=""
```
```env
DOWNLOAD_480P_NATIVE_MODELS=""
DOWNLOAD_720P_NATIVE_MODELS=""
DOWNLOAD_VACE=""
DOWNLOAD_WAN_FUN_AND_SDXL_HELPER=""
DOWNLOAD_STEADY_DANCER=""
DOWNLOAD_INFINITETALK=""
```
ComfyUI is set to pass the text encoder with fp8 flag by default, if you don't want
that set the following flag to `false`. Optionally you can enable FP8 for the UNET.
```env
USE_FP8_TEXT_ENC=""
USE_FP8_MODEL=""
```

NSFW friendly captioners - JoyCaption Beta One & Florence nsfw v2:
```env
DOWNLOAD_JOYCAPTION=""
DOWNLOAD_FLORENCE2=""
```

Pre-installed custom nodes:
- ComfyUI_UltimateSDUpscale  
- ComfyUI-KJNodes  
- ComfyUI-LivePortraitKJ  
- ComfyUI_wav2lip  
- ComfyUI-AnimateDiff-Evolved  
- ComfyUI_IPAdapter_plus
- ComfyUI-RIFE-TensorRT-Auto
- ComfyUI-Upscaler-TensorRT-Auto
- ComfyUI-QwenVL-Mod
- ComfyUI-Wan-SVI2Pro-FLF
- ComfyUI-HuggingFace  
- rgthree-comfy  
- ComfyUI_JPS-Nodes  
- ComfyUI_Comfyroll_CustomNodes  
- comfy-plasma  
- ComfyUI-VideoHelperSuite  
- mikey_nodes  
- ComfyUI-Impact-Pack  
- comfyui_controlnet_aux  
- ComfyUI-Easy-Use  
- ComfyUI-Florence2  
- ComfyUI-LatentSyncWrapper  
- was-node-suite-comfyui  
- ComfyUI-Logic  
- ComfyUI_essentials  
- cg-image-picker  
- ComfyUI_LayerStyle  
- cg-use-everywhere  
- ComfyUI-segment-anything-2  
- RES4LYF  
- ComfyUI-TeaCache  
- ComfyUI-Frame-Interpolation  
- ComfyUI-Detail-Daemon  
- ComfyUI-WanVideoWrapper  
- ComfyUI-VibeVoice  
- ComfyUI-WanAnimatePreprocess  
- ComfyUI-FSampler  
- ComfyUI-WanMoEScheduler  
- ComfyUI-VAE-Utils  
- ComfyUI-Wan22FMLF  
- ComfyUI_LayerStyle_Advance  
- masquerade-nodes-comfyui  
- ComfyUI-RMBG  
- ComfyLiterals


### Auth Tokens

```env
HUGGINGFACE_API_KEY=""
CIVITAI_TOKEN=""
SSH_PUBLIC_KEY=""
```

### Ports

| Port | Service  |
|------|----------|
| 8188 | ComfyUI  |
| 8888 | Jupyter  |
| 22   | SSH      |


### Accessing the Instance

```bash 
If you are using custom SSH key location you might want to create a config file in
~/.ssh/config for Linux or $HOME\.ssh\config for Windows.
```
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

You can transfer files using `rsync` and connect via SSH:

```bash
# Example: sync local dataset to remote
rsync -avP -e "ssh -p <SSH_PORT>" /path/to/local/dataset/ hostname@<SERVER_IP>:/path/to/remote/dataset/

# SSH with port forwarding for JupyterLab
ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8888:localhost:8888
```
Then open your browser to:
```bash
http://localhost:8888/lab
```

#### Accessing ComfyUI GUI

ComfyUI runs its interface on port `8188`. To access it from your local browser, use SSH port forwarding:

```bash
# SSH with port forwarding for ComfyUI
ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8188:localhost:8188
```
Then open your browser to:
```bash
http://localhost:8188
```
---

# Civitai Downloader

### 📖 Usage

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

### Command Line Arguments

| Argument     | Short | Description                          |
|--------------|-------|--------------------------------------|
| `--model-id` | `-m`  | CivitAI model version ID (required)  |
| `--output`   | `-o`  | Output directory                     |
| `--token`    | —     | CivitAI API token                    |
| `--filename` | —     | Override default filename            |
| `--force`    | —     | Force re-download                    |

---

### 🎯 Examples

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
