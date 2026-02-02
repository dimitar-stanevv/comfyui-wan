#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# Optional hook for custom setup before starting ComfyUI
if [ -f "/workspace/additional_params.sh" ]; then
    chmod +x /workspace/additional_params.sh
    echo "Executing additional_params.sh..."
    /workspace/additional_params.sh
else
    echo "additional_params.sh not found in /workspace. Skipping..."
fi

# Ensure aria2 is installed
if ! which aria2 > /dev/null 2>&1; then
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
else
    echo "aria2 is already installed"
fi

# Ensure curl is installed (needed to check if ComfyUI is up)
if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

# Start SageAttention build in the background (needed for PathchSageAttentionKJ node)
echo "Starting SageAttention build..."
(
    export EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=32
    cd /tmp
    git clone https://github.com/thu-ml/SageAttention.git
    cd SageAttention
    git reset --hard 68de379
    pip install -e .
    echo "SageAttention build completed" > /tmp/sage_build_done
) > /tmp/sage_build.log 2>&1 &
SAGE_PID=$!
echo "SageAttention build started in background (PID: $SAGE_PID)"

# Set the network volume path
NETWORK_VOLUME="/workspace"
URL="http://127.0.0.1:8188"

# Check if NETWORK_VOLUME exists; if not, use root directory instead
if [ ! -d "$NETWORK_VOLUME" ]; then
    echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. Setting NETWORK_VOLUME to '/' (root directory)."
    NETWORK_VOLUME="/"
    jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &
else
    echo "NETWORK_VOLUME directory exists. Starting JupyterLab..."
    jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/workspace &
fi

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"

# Move ComfyUI to network volume if not already there
if [ ! -d "$COMFYUI_DIR" ]; then
    mv /ComfyUI "$COMFYUI_DIR"
else
    echo "ComfyUI directory already exists, skipping move."
fi

# ============================================================
# CivitAI Downloader Setup
# ============================================================
echo "Setting up CivitAI download script..."
git clone "https://github.com/Hearmeman24/CivitAI_Downloader.git" || { echo "Git clone failed"; exit 1; }
mv CivitAI_Downloader/download_with_aria.py "/usr/local/bin/" || { echo "Move failed"; exit 1; }
chmod +x "/usr/local/bin/download_with_aria.py" || { echo "Chmod failed"; exit 1; }
rm -rf CivitAI_Downloader

# ============================================================
# Custom Nodes Setup (only what's needed for Wan 2.2 I2V workflow)
# ============================================================

# ComfyUI-WanVideoWrapper (core Wan support)
if [ ! -d "$NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper" ]; then
    cd $NETWORK_VOLUME/ComfyUI/custom_nodes
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git
else
    echo "Updating WanVideoWrapper"
    cd $NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper
    git pull
fi

# ComfyUI-KJNodes (for PathchSageAttentionKJ, ModelPassThrough)
if [ ! -d "$NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-KJNodes" ]; then
    cd $NETWORK_VOLUME/ComfyUI/custom_nodes
    git clone https://github.com/kijai/ComfyUI-KJNodes.git
fi
cd $NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-KJNodes
git pull

# Install dependencies in background
echo "🔧 Installing KJNodes packages..."
pip install --no-cache-dir -r $NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-KJNodes/requirements.txt &
KJ_PID=$!

echo "🔧 Installing WanVideoWrapper packages..."
pip install --no-cache-dir -r $NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt &
WAN_PID=$!

# ============================================================
# Model Downloads (only what's needed for Wan 2.2 I2V workflow)
# ============================================================

# Define base paths
DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"

# Create directories
mkdir -p "$DIFFUSION_MODELS_DIR"
mkdir -p "$TEXT_ENCODERS_DIR"
mkdir -p "$VAE_DIR"

# Function to download a model using aria2c
download_model() {
    local url="$1"
    local full_path="$2"

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # Simple corruption check: file < 10MB
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))

        if [ "$size_bytes" -lt 10485760 ]; then
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
        rm -f "$full_path"
    fi

    echo "📥 Downloading $destination_file to $destination_dir..."
    aria2c -x 16 -s 16 -k 1M --continue=true -d "$destination_dir" -o "$destination_file" "$url" &
    echo "Download started in background for $destination_file"
}

# Download Wan 2.2 I2V models (high noise + low noise)
echo "📥 Downloading Wan 2.2 I2V diffusion models..."
download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_i2v_high_noise_14B_fp16.safetensors"
download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_i2v_low_noise_14B_fp16.safetensors"

# Download text encoder
echo "📥 Downloading text encoder..."
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

# Download VAE
echo "📥 Downloading VAE..."
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$VAE_DIR/wan_2.1_vae.safetensors"

# Wait for all aria2c downloads to complete
echo "⏳ Waiting for model downloads to complete..."
while pgrep -x "aria2c" > /dev/null; do
    echo "🔽 Downloads still in progress..."
    sleep 5
done
echo "✅ All base models downloaded!"

# ============================================================
# CivitAI LoRA Downloads (via environment variables)
# ============================================================
LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"
mkdir -p "$LORAS_DIR"

declare -A MODEL_CATEGORIES=(
    ["$LORAS_DIR"]="$LORAS_IDS_TO_DOWNLOAD"
)

download_count=0

for TARGET_DIR in "${!MODEL_CATEGORIES[@]}"; do
    mkdir -p "$TARGET_DIR"
    MODEL_IDS_STRING="${MODEL_CATEGORIES[$TARGET_DIR]}"

    # Skip if empty or default placeholder
    if [[ -z "$MODEL_IDS_STRING" || "$MODEL_IDS_STRING" == "replace_with_ids" ]]; then
        echo "⏭️  No LoRAs to download (LORAS_IDS_TO_DOWNLOAD not set)"
        continue
    fi

    IFS=',' read -ra MODEL_IDS <<< "$MODEL_IDS_STRING"

    for MODEL_ID in "${MODEL_IDS[@]}"; do
        sleep 1
        echo "🚀 Downloading LoRA from CivitAI: $MODEL_ID to $TARGET_DIR"
        (cd "$TARGET_DIR" && download_with_aria.py -m "$MODEL_ID") &
        ((download_count++))
    done
done

if [ $download_count -gt 0 ]; then
    echo "📋 Scheduled $download_count CivitAI downloads in background"

    # Wait for CivitAI downloads to complete
    echo "⏳ Waiting for CivitAI downloads to complete..."
    while pgrep -x "aria2c" > /dev/null; do
        echo "🔽 LoRA downloads still in progress..."
        sleep 5
    done

    # Rename any .zip files to .safetensors (CivitAI quirk)
    echo "Renaming any zip files to safetensors..."
    cd $LORAS_DIR
    for file in *.zip; do
        [ -f "$file" ] && mv "$file" "${file%.zip}.safetensors"
    done

    echo "✅ All CivitAI downloads completed!"
fi

# ============================================================
# Move upscale model from Docker image
# ============================================================
echo "Setting up upscale models..."
mkdir -p "$NETWORK_VOLUME/ComfyUI/models/upscale_models"
if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/upscale_models/4xLSDIR.pth" ]; then
    if [ -f "/4xLSDIR.pth" ]; then
        mv "/4xLSDIR.pth" "$NETWORK_VOLUME/ComfyUI/models/upscale_models/4xLSDIR.pth"
        echo "✅ Moved 4xLSDIR.pth to upscale_models."
    else
        echo "⚠️  4xLSDIR.pth not found in root directory."
    fi
else
    echo "✅ 4xLSDIR.pth already exists."
fi

# ============================================================
# Download Workflow
# ============================================================
echo "📥 Downloading workflow..."
mkdir -p "$WORKFLOW_DIR"

WORKFLOW_FILE="$WORKFLOW_DIR/Wan2.2_I2V.json"
if [ ! -f "$WORKFLOW_FILE" ]; then
    curl -L -o "$WORKFLOW_FILE" "https://raw.githubusercontent.com/dimitar-stanevv/comfyui-wan/master/workflows/Wan%202.2/Video%20Generation/Wan2.2_I2V.json"
    echo "✅ Workflow downloaded: Wan2.2_I2V.json"
else
    echo "✅ Workflow already exists: Wan2.2_I2V.json"
fi

# ============================================================
# Enable Latent Preview by Default
# ============================================================
echo "Enabling latent preview for video generation..."

# Update VideoHelperSuite to enable latent preview by default
sed -i '/id: *'"'"'VHS.LatentPreview'"'"'/,/defaultValue:/s/defaultValue: false/defaultValue: true/' $NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/web/js/VHS.core.js

# Create/update ComfyUI-Manager config
CONFIG_PATH="$NETWORK_VOLUME/ComfyUI/user/default/ComfyUI-Manager"
CONFIG_FILE="$CONFIG_PATH/config.ini"

mkdir -p "$CONFIG_PATH"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating ComfyUI-Manager config.ini..."
    cat <<EOL > "$CONFIG_FILE"
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
    echo "Updating preview_method in existing config.ini..."
    sed -i 's/^preview_method = .*/preview_method = auto/' "$CONFIG_FILE"
fi
echo "✅ Latent preview enabled!"

# ============================================================
# Wait for pip installs to complete
# ============================================================
echo "⏳ Waiting for pip installs to complete..."

wait $KJ_PID
KJ_STATUS=$?

wait $WAN_PID
WAN_STATUS=$?

if [ $KJ_STATUS -eq 0 ]; then
    echo "✅ KJNodes install complete"
else
    echo "❌ KJNodes install failed"
fi

if [ $WAN_STATUS -eq 0 ]; then
    echo "✅ WanVideoWrapper install complete"
else
    echo "❌ WanVideoWrapper install failed"
fi

# Workspace as main working directory
echo "cd $NETWORK_VOLUME" >> ~/.bashrc

# ============================================================
# Wait for SageAttention build
# ============================================================
echo "⏳ Waiting for SageAttention build to complete..."
while ! [ -f /tmp/sage_build_done ]; do
    if ps -p $SAGE_PID > /dev/null 2>&1; then
        echo "⚙️  SageAttention build in progress (may take up to 5 minutes)..."
        sleep 5
    else
        if ! [ -f /tmp/sage_build_done ]; then
            echo "⚠️  SageAttention build ended unexpectedly. Check /tmp/sage_build.log"
            break
        fi
    fi
done

if [ -f /tmp/sage_build_done ]; then
    echo "✅ SageAttention build completed!"
fi

# ============================================================
# Start ComfyUI
# ============================================================
echo "▶️  Starting ComfyUI..."

nohup python3 "$NETWORK_VOLUME/ComfyUI/main.py" --listen --use-sage-attention > "$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &

counter=0
max_wait=45

until curl --silent --fail "$URL" --output /dev/null; do
    if [ $counter -ge $max_wait ]; then
        echo "⚠️  ComfyUI should be up by now. If not running, check logs:"
        echo "   cat $NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log"
        break
    fi

    echo "🔄 ComfyUI starting up... (logs: $NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log)"
    sleep 2
    counter=$((counter + 2))
done

if curl --silent --fail "$URL" --output /dev/null; then
    echo "🚀 ComfyUI is UP!"
    
    # Send push notification via ntfy.sh (free, no account needed)
    # Set NTFY_TOPIC env variable in your vast.ai template to receive notifications
    if [ -n "$NTFY_TOPIC" ]; then
        curl -s \
            -H "Title: ComfyUI Ready 🚀" \
            -H "Priority: high" \
            -H "Tags: white_check_mark,rocket" \
            -d "ComfyUI is UP and ready to use!" \
            "https://ntfy.sh/$NTFY_TOPIC" > /dev/null 2>&1
        echo "📱 Notification sent to ntfy.sh topic"
    fi
fi

sleep infinity
