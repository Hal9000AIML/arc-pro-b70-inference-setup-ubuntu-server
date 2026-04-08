#!/usr/bin/env bash
# =============================================================================
# Intel B70 Inference Server — Automated Setup Script v1.2.0
#
# Sets up Intel Arc Pro B70 GPUs for LLM inference with vLLM tensor parallelism.
# Tested on Ubuntu Server 24.04 LTS with 2x and 4x B70 configurations.
#
# Hardware requirements:
#   - 1-4x Intel Arc Pro B70 GPUs (32GB VRAM each)
#   - 64GB+ system RAM (128GB recommended for large MoE models)
#   - PCIe x16 slots (Gen 3.0+ works, Gen 5.0 optimal)
#   - Ubuntu Server 24.04 LTS
#
# BIOS requirements (must be set manually before running this script):
#   - Above 4G Decoding: ENABLED
#   - Resizable BAR: ENABLED
#   - CSM: DISABLED (UEFI boot only)
#
# Usage:
#   chmod +x odin-b70-setup.sh
#   sudo ./odin-b70-setup.sh
#
# After running, reboot and then:
#   ~/boot_vllm.sh        # Start vLLM with tensor parallelism
#   ~/start_llamacpp.sh   # Or start llama.cpp for single-GPU inference
#
# Based on testing by Level1Techs (550 tok/s on 4x B70)
# =============================================================================
set -euo pipefail

SCRIPT_VERSION="1.3.0"
LOG="/var/log/odin-b70-setup.log"

# --- Configuration (edit these) ---
VLLM_MODEL="google/gemma-4-26B-A4B-it"             # HuggingFace model for vLLM
VLLM_MODEL_NAME="gemma-4-26B-A4B"                   # Served model name
VLLM_PORT=8000                                  # vLLM API port
LLAMACPP_PORT=8080                              # llama.cpp fallback port
KERNEL_VERSION="6.17.0-20-generic"              # Minimum kernel for B70
COMPUTE_RUNTIME_VERSION="26.09.37435.1"         # GitHub release tag
IGC_VERSION="v2.30.1"                           # Intel Graphics Compiler
VLLM_DOCKER_IMAGE="vllm-xpu:local"             # Built from source for Gemma 4 support
# ----------------------------------

touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "================================================================"
echo "Intel B70 Inference Server Setup v${SCRIPT_VERSION} — $(date)"
echo "================================================================"

# -----------------------------------------------------------
# 0. Sanity checks
# -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo ./odin-b70-setup.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
    echo "ERROR: Do not run as root directly. Use: sudo ./odin-b70-setup.sh"
    echo "       The script needs SUDO_USER to identify your non-root account."
    exit 1
fi

REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
    echo "ERROR: Could not determine home directory for user '${REAL_USER}'"
    exit 1
fi

echo "User: ${REAL_USER} | Home: ${REAL_HOME}"
echo ""

# Check for B70 GPUs
B70_COUNT=$(lspci | grep -c "Intel.*e223" 2>/dev/null || echo 0)
if [[ "$B70_COUNT" -eq 0 ]]; then
    echo "WARNING: No Intel Arc Pro B70 GPUs detected (device e223)."
    echo "         Make sure BIOS has Above 4G Decoding and ReBAR enabled."
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
else
    echo "Detected ${B70_COUNT}x Intel Arc Pro B70 GPU(s)"
fi

echo ""
NEED_REBOOT=false

# -----------------------------------------------------------
# 1. System update & essential packages
# -----------------------------------------------------------
echo ">>> [1/11] System update & essentials"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential cmake git curl wget \
    htop lm-sensors \
    pkg-config libssl-dev \
    software-properties-common \
    ca-certificates gpg \
    python3 python3-pip python3-venv \
    unzip pciutils lshw numactl \
    clinfo glslang-tools \
    vulkan-tools libvulkan-dev libvulkan1 \
    mesa-vulkan-drivers
echo "    Done."

# -----------------------------------------------------------
# 2. Install kernel 6.17+ (Battlemage xe driver support)
# -----------------------------------------------------------
echo ""
echo ">>> [2/11] Kernel 6.17+ for Battlemage xe driver"

CURRENT_KERNEL=$(uname -r)
CURRENT_MAJOR=$(echo "$CURRENT_KERNEL" | cut -d. -f1)
CURRENT_MINOR=$(echo "$CURRENT_KERNEL" | cut -d. -f2)

if [[ "$CURRENT_MAJOR" -lt 6 ]] || [[ "$CURRENT_MAJOR" -eq 6 && "$CURRENT_MINOR" -lt 17 ]]; then
    echo "    Current kernel: ${CURRENT_KERNEL} (too old for B70)"
    echo "    Installing kernel ${KERNEL_VERSION}..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "linux-image-${KERNEL_VERSION}" \
        "linux-modules-${KERNEL_VERSION}" \
        "linux-modules-extra-${KERNEL_VERSION}" 2>/dev/null || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "linux-image-unsigned-${KERNEL_VERSION}" \
        "linux-modules-${KERNEL_VERSION}" \
        "linux-modules-extra-${KERNEL_VERSION}" 2>/dev/null || {
            echo "    WARNING: Could not install kernel ${KERNEL_VERSION}."
            echo "    Searching for latest 6.17+ kernel..."
            KERNEL_VERSION=$(apt-cache search linux-image | grep -E "6\.(1[7-9]|[2-9][0-9]).*generic" | grep -v unsigned | grep -v dbg | sort -V | tail -1 | awk '{print $1}' | sed 's/linux-image-//')
            if [[ -n "$KERNEL_VERSION" ]]; then
                echo "    Found: ${KERNEL_VERSION}"
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    "linux-image-${KERNEL_VERSION}" \
                    "linux-modules-${KERNEL_VERSION}" \
                    "linux-modules-extra-${KERNEL_VERSION}"
            else
                echo "    ERROR: No 6.17+ kernel found. Add the HWE PPA or install manually."
                exit 1
            fi
        }
    NEED_REBOOT=true
else
    echo "    Current kernel: ${CURRENT_KERNEL} (OK)"
fi

# Set GRUB parameters
if ! grep -q "iommu=pt" /etc/default/grub; then
    cp /etc/default/grub /etc/default/grub.bak
    # Restore backup on failure
    trap 'cp /etc/default/grub.bak /etc/default/grub 2>/dev/null; echo "GRUB restored from backup"' ERR
    CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//;s/"$//')
    NEW_CMDLINE="${CURRENT_CMDLINE:+$CURRENT_CMDLINE }iommu=pt pci=realloc"
    # Write the new line using python to avoid sed delimiter issues
    NEW_CMDLINE="${NEW_CMDLINE}" python3 - << 'GRUBPY'
import re, os
new_val = os.environ['NEW_CMDLINE']
with open('/etc/default/grub', 'r') as f:
    content = f.read()
content = re.sub(
    r'^GRUB_CMDLINE_LINUX_DEFAULT=.*$',
    f'GRUB_CMDLINE_LINUX_DEFAULT="{new_val}"',
    content, flags=re.MULTILINE
)
with open('/etc/default/grub', 'w') as f:
    f.write(content)
GRUBPY
    update-grub 2>&1 | tee -a "$LOG"
    trap - ERR
    echo "    GRUB: added iommu=pt pci=realloc"
    NEED_REBOOT=true
fi

echo "    Done."

# -----------------------------------------------------------
# 3. Intel GPU drivers (compute-runtime from GitHub)
# -----------------------------------------------------------
echo ""
echo ">>> [3/11] Intel GPU drivers (compute-runtime ${COMPUTE_RUNTIME_VERSION})"

# Add Intel graphics APT repo for base packages
mkdir -p /etc/apt/keyrings
wget -qO- https://repositories.intel.com/gpu/intel-graphics.key | \
    gpg --dearmor -o /etc/apt/keyrings/intel-graphics.gpg 2>/dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/intel-graphics.gpg] \
https://repositories.intel.com/gpu/ubuntu noble unified" \
    > /etc/apt/sources.list.d/intel-gpu.list
apt-get update -qq

# Install Level Zero loader
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq level-zero libze1 2>/dev/null || true

# Install compute-runtime from GitHub (APT repo version doesn't support BMG e223)
echo "    Downloading compute-runtime ${COMPUTE_RUNTIME_VERSION} from GitHub..."
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"

CR_BASE="https://github.com/intel/compute-runtime/releases/download/${COMPUTE_RUNTIME_VERSION}"
wget -q "${CR_BASE}/libze-intel-gpu1_${COMPUTE_RUNTIME_VERSION}-0_amd64.deb"
wget -q "${CR_BASE}/intel-opencl-icd_${COMPUTE_RUNTIME_VERSION}-0_amd64.deb"
wget -q "${CR_BASE}/intel-ocloc_${COMPUTE_RUNTIME_VERSION}-0_amd64.deb"
wget -q "${CR_BASE}/libigdgmm12_22.9.0_amd64.deb" || true

echo "    Downloading IGC ${IGC_VERSION}..."
IGC_BASE="https://github.com/intel/intel-graphics-compiler/releases/download/${IGC_VERSION}"
IGC_TAG=$(echo "$IGC_VERSION" | sed 's/^v//')
wget -q "${IGC_BASE}/intel-igc-core-2_${IGC_TAG}+20950_amd64.deb" || \
wget -q "${IGC_BASE}/intel-igc-core_${IGC_TAG}_amd64.deb" || true
wget -q "${IGC_BASE}/intel-igc-opencl-2_${IGC_TAG}+20950_amd64.deb" || \
wget -q "${IGC_BASE}/intel-igc-opencl_${IGC_TAG}_amd64.deb" || true

# Validate downloaded .deb files
echo "    Validating packages..."
for deb in *.deb; do
    [[ -f "$deb" ]] || continue
    if ! file "$deb" | grep -q "Debian binary package"; then
        echo "    WARNING: $deb is not a valid Debian package, skipping"
        rm -f "$deb"
    fi
done

echo "    Installing..."
# Remove conflicting old packages
dpkg -r intel-opencl-icd libze-intel-gpu1 intel-ocloc libigc1 libigdfcl1 libigc2 libigdfcl2 2>/dev/null || true

for deb in libigdgmm12_*.deb intel-igc-core*.deb intel-igc-opencl*.deb libze-intel-gpu1_*.deb intel-opencl-icd_*.deb intel-ocloc_*.deb; do
    [[ -f "$deb" ]] || continue
    dpkg -i "$deb" || echo "    WARNING: Failed to install $deb"
done
ldconfig

cd /
rm -rf "$WORK_DIR"

# GuC + HuC firmware update for Battlemage
#
# Background: with linux-firmware shipping GuC 70.44.1, all four B70 GPUs
# experienced blitter-engine (bcs) hangs requiring GuC engine resets under
# sustained vLLM load, which cascaded into vLLM EngineCore RPC timeouts and
# killed the API server. The kernel xe driver itself logs:
#   "GuC firmware (70.45.2) is recommended, but only (70.44.1) was found"
#
# Verified working on production 4x B70 install: GuC 70.60.0 + HuC 8.2.10 from
# linux-firmware.git HEAD, installed as zstd-compressed .bin.zst files.
#
# CRITICAL: the xe driver loads bmg_guc_70.bin.zst (compressed). Placing an
# uncompressed bmg_guc_70.bin next to it will take precedence and crash all
# GPUs with -EINVAL. ALWAYS install as .bin.zst, never as raw .bin.
echo "    Updating GuC + HuC firmware from linux-firmware.git HEAD..."
apt-get install -y --only-upgrade -qq linux-firmware >/dev/null 2>&1 || true
apt-get install -y -qq zstd >/dev/null 2>&1
FW_TMP=$(mktemp -d)
LF_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/xe"
if curl -fsSLo "$FW_TMP/bmg_guc_70.bin" "$LF_BASE/bmg_guc_70.bin" && \
   curl -fsSLo "$FW_TMP/bmg_huc.bin"   "$LF_BASE/bmg_huc.bin"; then
    zstd -19 -q -f -o "$FW_TMP/bmg_guc_70.bin.zst" "$FW_TMP/bmg_guc_70.bin"
    zstd -19 -q -f -o "$FW_TMP/bmg_huc.bin.zst"   "$FW_TMP/bmg_huc.bin"
    mkdir -p /lib/firmware/xe
    # Backup any existing files before overwriting
    [[ -f /lib/firmware/xe/bmg_guc_70.bin.zst ]] && \
        cp /lib/firmware/xe/bmg_guc_70.bin.zst /lib/firmware/xe/bmg_guc_70.bin.zst.bak.$(date +%s)
    [[ -f /lib/firmware/xe/bmg_huc.bin.zst ]] && \
        cp /lib/firmware/xe/bmg_huc.bin.zst /lib/firmware/xe/bmg_huc.bin.zst.bak.$(date +%s)
    # CRITICAL: remove any uncompressed .bin that would shadow the .bin.zst
    rm -f /lib/firmware/xe/bmg_guc_70.bin /lib/firmware/xe/bmg_huc.bin
    install -m 644 "$FW_TMP/bmg_guc_70.bin.zst" /lib/firmware/xe/bmg_guc_70.bin.zst
    install -m 644 "$FW_TMP/bmg_huc.bin.zst"   /lib/firmware/xe/bmg_huc.bin.zst
    update-initramfs -u >/dev/null 2>&1 || true
    echo "    GuC/HuC firmware updated. New versions will load on next boot."
else
    echo "    NOTE: Could not fetch firmware from linux-firmware.git (no internet?)."
    echo "    Falling back to distro linux-firmware package."
fi
rm -rf "$FW_TMP"

# Add user to render and video groups
usermod -aG render "${REAL_USER}" 2>/dev/null || true
usermod -aG video "${REAL_USER}" 2>/dev/null || true

echo "    Done."

# -----------------------------------------------------------
# 4. Docker
# -----------------------------------------------------------
echo ""
echo ">>> [4/11] Docker"

if ! command -v docker &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
    systemctl enable docker
    systemctl start docker
    echo "    Installed Docker $(docker --version | awk '{print $3}')"
else
    echo "    Docker already installed: $(docker --version | awk '{print $3}')"
fi

usermod -aG docker "${REAL_USER}" 2>/dev/null || true

# Install Docker buildx (required for building vLLM from source)
if ! docker buildx version &>/dev/null; then
    echo "    Installing Docker buildx..."
    mkdir -p "${REAL_HOME}/.docker/cli-plugins"
    curl -sL "https://github.com/docker/buildx/releases/download/v0.23.0/buildx-v0.23.0.linux-amd64" \
        -o "${REAL_HOME}/.docker/cli-plugins/docker-buildx"
    chmod +x "${REAL_HOME}/.docker/cli-plugins/docker-buildx"
    chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.docker/cli-plugins/docker-buildx"
    echo "    Buildx installed: $(docker buildx version)"
else
    echo "    Docker buildx already installed"
fi
echo "    Done."

# -----------------------------------------------------------
# 5. Build vLLM Docker image from source (Gemma 4 support)
# -----------------------------------------------------------
echo ""
echo ">>> [5/11] Building vLLM XPU Docker image from source"
echo "    This builds from vLLM main branch for latest model support."
echo "    This will take 30-60 minutes..."

VLLM_BUILD_DIR=$(mktemp -d)
cd "$VLLM_BUILD_DIR"
sudo -u "${REAL_USER}" git clone --depth 1 https://github.com/vllm-project/vllm.git .

if ! docker buildx build -f docker/Dockerfile.xpu -t "${VLLM_DOCKER_IMAGE}" --target vllm-openai --load . 2>&1 | tee -a "$LOG"; then
    echo "    ERROR: vLLM Docker build failed"
    echo "    Falling back to pre-built image..."
    docker pull intel/vllm:0.17.0-xpu
    VLLM_DOCKER_IMAGE="intel/vllm:0.17.0-xpu"
fi

# Upgrade transformers inside container for Gemma 4 architecture support
echo "    Upgrading transformers for Gemma 4 support..."
docker run --rm "${VLLM_DOCKER_IMAGE}" pip install 'transformers>=4.59' 2>/dev/null || true

cd /
rm -rf "$VLLM_BUILD_DIR"
echo "    Done."

# -----------------------------------------------------------
# 6. Build llama.cpp (Vulkan, single-GPU fallback)
# -----------------------------------------------------------
echo ""
echo ">>> [6/11] Building llama.cpp (Vulkan backend)"

LLAMA_DIR="${REAL_HOME}/llama.cpp"
if [[ -d "${LLAMA_DIR}" ]]; then
    sudo -u "${REAL_USER}" git -C "${LLAMA_DIR}" pull -q
else
    sudo -u "${REAL_USER}" git clone -q https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
fi

rm -rf "${LLAMA_DIR}/build"
sudo -u "${REAL_USER}" cmake -S "${LLAMA_DIR}" -B "${LLAMA_DIR}/build" \
    -DGGML_VULKAN=ON -DGGML_SYCL=OFF -DGGML_CUDA=OFF \
    -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON 2>&1 | tail -1
sudo -u "${REAL_USER}" cmake --build "${LLAMA_DIR}/build" --config Release -j$(nproc) 2>&1 | tail -1
echo "    Built: ${LLAMA_DIR}/build/bin/llama-server"

# -----------------------------------------------------------
# 7. Download default model
# -----------------------------------------------------------
echo ""
echo ">>> [7/11] Downloading model: ${VLLM_MODEL}"

MODEL_DIR="${REAL_HOME}/models"
MODEL_LOCAL_NAME=$(echo "$VLLM_MODEL" | tr '/' '-')
MODEL_PATH="${MODEL_DIR}/${MODEL_LOCAL_NAME}"

sudo -u "${REAL_USER}" mkdir -p "${MODEL_DIR}"

if [[ -d "${MODEL_PATH}" ]] && [[ $(find "${MODEL_PATH}" -name "*.safetensors" 2>/dev/null | wc -l) -gt 0 ]]; then
    echo "    Model already downloaded at ${MODEL_PATH}"
else
    echo "    Installing huggingface_hub..."
    sudo -u "${REAL_USER}" pip install --break-system-packages -q huggingface_hub 2>/dev/null || \
    pip install --break-system-packages -q huggingface_hub 2>/dev/null || true

    echo "    Downloading (this may take a while)..."
    VLLM_MODEL="${VLLM_MODEL}" MODEL_PATH="${MODEL_PATH}" \
    sudo -u "${REAL_USER}" python3 - << 'PYEOF'
import os
from huggingface_hub import snapshot_download
snapshot_download(os.environ['VLLM_MODEL'], local_dir=os.environ['MODEL_PATH'])
print('Download complete!')
PYEOF
fi

echo "    Done."

# -----------------------------------------------------------
# 8. Create chat template and swap file
# -----------------------------------------------------------
echo ""
echo ">>> [8/11] Chat template and swap configuration"

# Create Gemma 4 chat template (required by transformers 5.x)
cat > "${MODEL_PATH}/chat_template.jinja" << 'CHATEOF'
{{ bos_token }}{% for message in messages %}{% if message['role'] == 'system' %}<start_of_turn>system
{{ message['content'] }}<end_of_turn>
{% elif message['role'] == 'user' %}<start_of_turn>user
{{ message['content'] }}<end_of_turn>
{% elif message['role'] == 'assistant' %}<start_of_turn>model
{{ message['content'] }}<end_of_turn>
{% endif %}{% endfor %}<start_of_turn>model
CHATEOF
chown "${REAL_USER}:${REAL_USER}" "${MODEL_PATH}/chat_template.jinja"
echo "    Chat template created"

# Create swap file if RAM < 64GB (needed for mmap of large model shards)
TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
if [[ "$TOTAL_RAM_GB" -lt 64 ]]; then
    SWAP_SIZE=$((64 - TOTAL_RAM_GB + 16))
    echo "    System has ${TOTAL_RAM_GB}GB RAM — creating ${SWAP_SIZE}GB swap file..."
    if [[ ! -f /swapfile_vllm ]]; then
        fallocate -l "${SWAP_SIZE}G" /swapfile_vllm
        chmod 600 /swapfile_vllm
        mkswap /swapfile_vllm
        swapon /swapfile_vllm
        echo "/swapfile_vllm none swap sw 0 0" >> /etc/fstab
        echo "    Swap file created and enabled (persistent across reboots)"
    else
        echo "    Swap file already exists"
    fi
else
    echo "    System has ${TOTAL_RAM_GB}GB RAM — no extra swap needed"
fi
echo "    Done."

# -----------------------------------------------------------
# 9. Create scripts and systemd services
# -----------------------------------------------------------
echo ""
echo ">>> [9/11] Creating scripts and services"

# Detect GPU count
GPU_COUNT=$(lspci | grep -c "Intel.*e223" 2>/dev/null || echo 0)
[[ "$GPU_COUNT" -eq 0 ]] && GPU_COUNT=2  # Default assumption

# --- vLLM startup script ---
cat > "${REAL_HOME}/start_vllm.sh" << VLLMSCRIPT
#!/usr/bin/env bash
# Start vLLM with tensor parallelism across all B70 GPUs
GPU_COUNT=\$(lspci | grep -c "Intel.*e223" 2>/dev/null || echo ${GPU_COUNT})

if ! docker ps --format '{{.Names}}' | grep -q '^vllm-b70\$'; then
    echo "ERROR: Container vllm-b70 is not running. Run ${REAL_HOME}/boot_vllm.sh first."
    exit 1
fi

# Idempotency guard: check if vllm is ALREADY HEALTHY (listening on port and
# responding to /health), not just if the process exists. A crashed vllm
# often leaves orphaned worker processes or a zombie bash wrapper that would
# match 'pgrep -f "vllm serve"' — an earlier version of this guard did that
# and refused to start a new vllm after a hang, leaving the bot stack dead.
if curl -sf --max-time 3 "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null 2>&1; then
    echo "vLLM already healthy on port ${VLLM_PORT} — skipping start"
    exit 0
fi
# If we get here, vllm is not healthy. Clean up any orphaned processes +
# shared-memory segments before spawning a fresh one.
if docker exec vllm-b70 pgrep -f 'vllm serve' >/dev/null 2>&1; then
    echo "vLLM process exists but port ${VLLM_PORT} is not responding — cleaning up orphans"
    "${REAL_HOME}/stop_vllm.sh" || true
    sleep 2
fi

docker exec -d vllm-b70 bash -c "
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export UR_L0_USE_IMMEDIATE_COMMANDLISTS=0
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export CCL_TOPO_P2P_ACCESS=0

vllm serve /llm/models/${MODEL_LOCAL_NAME} \\
  --served-model-name ${VLLM_MODEL_NAME} \\
  --port ${VLLM_PORT} \\
  --host 0.0.0.0 \\
  --dtype bfloat16 \\
  --quantization fp8 \\
  --enforce-eager \\
  --disable-custom-all-reduce \\
  --tensor-parallel-size ${GPU_COUNT} \\
  --gpu-memory-util 0.65 \\
  --block-size 64 \\
  --max-model-len 32768 \\
  --max-num-seqs 8 \\
  --enable-auto-tool-choice \\
  --tool-call-parser gemma4 \\
  --enable-chunked-prefill \\
  --no-enable-prefix-caching \\
  --trust-remote-code \\
  --chat-template /llm/models/${MODEL_LOCAL_NAME}/chat_template.jinja \\
  2>&1 | tee -a /tmp/vllm.log
"
echo "vLLM starting (${VLLM_MODEL_NAME}, TP=\${GPU_COUNT})..."
echo "Health check: curl http://localhost:${VLLM_PORT}/health"
VLLMSCRIPT

# --- vLLM graceful stop script ---
# Without this, restarting vllm-serve leaves the old vllm process AND its
# leaked /dev/shm segments alive — XPU VRAM never frees and the new vllm
# fails with "Free memory on device xpu:0 (0.02/30.3 GiB)".
cat > "${REAL_HOME}/stop_vllm.sh" << 'STOPSCRIPT'
#!/usr/bin/env bash
# Gracefully stop vLLM inside the container so XPU VRAM and shared memory
# segments are released. SIGKILL leaks shm; SIGTERM lets vLLM clean up.
if ! docker ps --format '{{.Names}}' | grep -q '^vllm-b70$'; then
    exit 0
fi
docker exec vllm-b70 bash -c '
  pids=$(pgrep -f "vllm serve" || true)
  if [ -n "$pids" ]; then
    kill -TERM $pids 2>/dev/null || true
    for i in $(seq 1 30); do
      pgrep -f "vllm serve" >/dev/null || break
      sleep 1
    done
    pkill -9 -f "vllm serve" 2>/dev/null || true
  fi
  # Sweep leaked POSIX shm segments left behind by vLLM workers
  rm -f /dev/shm/psm_* /dev/shm/vllm_* 2>/dev/null || true
' || true
STOPSCRIPT
chmod +x "${REAL_HOME}/stop_vllm.sh"
chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/stop_vllm.sh"

# --- Full boot script ---
cat > "${REAL_HOME}/boot_vllm.sh" << BOOTEOF
#!/usr/bin/env bash
# Full boot: start Docker container, then vLLM server
echo "Starting Docker container..."
docker stop vllm-b70 2>/dev/null || true
docker rm vllm-b70 2>/dev/null || true

docker run -d --privileged --shm-size 32g --net=host --ipc=host \\
  --restart=unless-stopped \\
  -v "${MODEL_DIR}:/llm/models" \\
  --name=vllm-b70 \\
  --entrypoint="" ${VLLM_DOCKER_IMAGE} sleep infinity

sleep 5

# Verify container is running
if ! docker ps --format '{{.Names}}' | grep -q '^vllm-b70\$'; then
    echo "ERROR: Container failed to start. Check: docker logs vllm-b70"
    exit 1
fi

# Upgrade transformers for Gemma 4 (needed until vLLM pins a compatible version)
echo "Upgrading transformers..."
docker exec vllm-b70 pip install -q 'transformers>=4.59' 2>/dev/null || true

echo "Starting vLLM server..."
${REAL_HOME}/start_vllm.sh

echo "Waiting for vLLM health check..."
for i in \$(seq 1 180); do
    if curl -sf -o /dev/null http://127.0.0.1:${VLLM_PORT}/health 2>/dev/null; then
        echo "vLLM READY after \$((i*2))s!"
        echo "API: http://\$(hostname -I | awk '{print \$1}'):${VLLM_PORT}"
        exit 0
    fi
    sleep 2
done
echo "WARNING: vLLM did not become ready within 360s."
echo "Check logs: docker exec vllm-b70 tail -30 /tmp/vllm.log"
BOOTEOF

# --- llama.cpp startup script ---
cat > "${REAL_HOME}/start_llamacpp.sh" << LLAMASCRIPT
#!/usr/bin/env bash
# Start llama.cpp Vulkan server (single-GPU, fast for GGUF models)
MODEL="\${1:-\${HOME}/models/active_model.gguf}"
[[ -f "\$MODEL" ]] || { echo "Model not found: \$MODEL"; echo "Usage: \$0 <path_to_gguf>"; exit 1; }
echo "Starting llama.cpp Vulkan on port ${LLAMACPP_PORT}..."
\${HOME}/llama.cpp/build/bin/llama-server \\
    -m "\$MODEL" -ngl 99 \\
    --flash-attn \\
    --cache-type-k q8_0 --cache-type-v q8_0 \\
    --host 0.0.0.0 --port ${LLAMACPP_PORT} \\
    --ctx-size 4096 --parallel 4 --threads \$(nproc)
LLAMASCRIPT

# --- System info script ---
cat > "${REAL_HOME}/sysinfo.sh" << SYSSCRIPT
#!/usr/bin/env bash
echo "=== ODIN Inference Server ==="
echo "Hostname: \$(hostname)"
echo "IP:       \$(hostname -I | awk '{print \$1}')"
echo "Kernel:   \$(uname -r)"
echo "Uptime:   \$(uptime -p)"
echo "RAM:      \$(free -h | awk '/Mem:/{print \$3"/"\$2}')"
echo "Disk:     \$(df -h / | awk 'NR==2{print \$3"/"\$2" ("\$5" used)"}')"
echo ""
echo "=== GPUs ==="
lspci | grep -i "vga\|display\|3d"
echo ""
echo "=== GPU Temps ==="
sensors 2>/dev/null | grep -A3 'xe-pci' || echo "(install lm-sensors or use kernel 6.17+)"
echo ""
echo "=== Vulkan Devices ==="
vulkaninfo --summary 2>/dev/null | grep -A2 "deviceName" || echo "(not available)"
echo ""
echo "=== Services ==="
docker ps --format "  vLLM Docker: {{.Names}} ({{.Status}})" 2>/dev/null || echo "  Docker: not running"
if curl -sf -o /dev/null http://127.0.0.1:${VLLM_PORT}/health 2>/dev/null; then
    echo "  vLLM API: healthy (port ${VLLM_PORT})"
else
    echo "  vLLM API: not running (port ${VLLM_PORT})"
fi
SYSSCRIPT

# --- GPU thermal watchdog script ---
cat > "${REAL_HOME}/gpu_thermal_watchdog.sh" << 'THERMALEOF'
#!/usr/bin/env bash
THRESHOLD=90
LOG=/var/log/gpu_thermal.log
while true; do
    MAX_TEMP=0
    while IFS= read -r line; do
        case "$line" in *C*) ;; *) continue ;; esac
        temp=$(echo "$line" | sed -n "s/.*+\([0-9]*\)\..*/\1/p")
        if [ -n "$temp" ] && [ "$temp" -gt "$MAX_TEMP" ] 2>/dev/null; then
            MAX_TEMP=$temp
        fi
    done < <(sensors 2>/dev/null | grep -E "^\s*(pkg|vram):" | grep -v MJ | grep -v W)
    if [ "$MAX_TEMP" -gt 0 ] && [ "$MAX_TEMP" -ge "$THRESHOLD" ]; then
        echo "$(date): CRITICAL GPU temp ${MAX_TEMP}C >= ${THRESHOLD}C stopping vLLM" | tee -a $LOG
        docker exec vllm-b70 pkill -f "vllm serve" 2>/dev/null
        docker stop vllm-b70 2>/dev/null
        echo "$(date): vLLM stopped for thermal protection" | tee -a $LOG
    fi
    sleep 30
done
THERMALEOF

# Set permissions
for script in start_vllm boot_vllm start_llamacpp sysinfo gpu_thermal_watchdog; do
    if [[ -f "${REAL_HOME}/${script}.sh" ]]; then
        chmod +x "${REAL_HOME}/${script}.sh"
        chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/${script}.sh"
    fi
done

# --- Systemd service for Docker container ---
cat > /etc/systemd/system/vllm-docker.service << EOF
[Unit]
Description=vLLM Docker Container (ODIN)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=300
TimeoutStopSec=30
ExecStartPre=-/usr/bin/docker stop vllm-b70
ExecStartPre=-/usr/bin/docker rm vllm-b70
ExecStart=/usr/bin/docker run -d --privileged --shm-size 32g --net=host --ipc=host --restart=unless-stopped -v ${MODEL_DIR}:/llm/models --name=vllm-b70 --entrypoint= ${VLLM_DOCKER_IMAGE} sleep infinity
ExecStop=/usr/bin/docker stop -t 15 vllm-b70

[Install]
WantedBy=multi-user.target
EOF

# --- Systemd service for GPU thermal watchdog ---
cat > /etc/systemd/system/gpu-thermal-watchdog.service << EOF
[Unit]
Description=GPU Thermal Watchdog (ODIN)
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=${REAL_HOME}/gpu_thermal_watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- vLLM watchdog script (auto-restart on crash or hang) ---
# IMPORTANT: the authoritative liveness check is an HTTP probe of /health,
# NOT 'pgrep vllm serve'. When vLLM hangs on a GPU blitter-engine reset, the
# EngineCore dies but orphaned worker processes (and the bash wrapper) can
# linger — pgrep would incorrectly report vllm as alive and the watchdog
# would never restart it. Observed failure: engine_class=bcs GuC reset ->
# RPC call to sample_tokens timed out -> EngineCore dead -> port 8000 dead.
cat > "${REAL_HOME}/watchdog_vllm.sh" << WATCHEOF
#!/usr/bin/env bash
LOG=${REAL_HOME}/watchdog.log
HEALTH_URL="http://127.0.0.1:${VLLM_PORT}/health"
CONSECUTIVE_FAILURES=0
FAILURE_THRESHOLD=2     # 2 consecutive failures (60s) between checks
STUCK_THRESHOLD=300     # up to 10 min for model load after a restart
STARTUP_GRACE=600       # up to 20 min for first-boot model load (cold cache)

echo "\$(date): Watchdog started (health-check mode)" >> \$LOG

# Startup grace period: wait for initial health before enforcing the
# failure threshold. Prevents the watchdog from killing in-progress model
# loads on boot or after an operator-initiated restart. Model load on cold
# cache + swap-backed systems can take 10+ minutes.
echo "\$(date): Entering startup grace (up to \$STARTUP_GRACE seconds)" >> \$LOG
for i in \$(seq 1 \$STARTUP_GRACE); do
    if curl -sf --max-time 3 "\$HEALTH_URL" >/dev/null 2>&1; then
        echo "\$(date): Initial health OK after \${i}s" >> \$LOG
        break
    fi
    sleep 1
done

restart_vllm() {
    echo "\$(date): Triggering vLLM restart" >> \$LOG
    # Capture full diagnostic snapshot before tearing down
    /usr/local/bin/gpu_diag_logger.sh --on-failure >/dev/null 2>&1 || true
    "${REAL_HOME}/stop_vllm.sh" 2>>\$LOG || true
    sleep 3
    "${REAL_HOME}/start_vllm.sh" >>\$LOG 2>&1 || true
    # Wait for /health to come back (up to \$STUCK_THRESHOLD * 2 seconds)
    for i in \$(seq 1 \$STUCK_THRESHOLD); do
        if curl -sf --max-time 3 "\$HEALTH_URL" >/dev/null 2>&1; then
            echo "\$(date): vLLM healthy after \$((i*2))s" >> \$LOG
            CONSECUTIVE_FAILURES=0
            return 0
        fi
        sleep 2
    done
    echo "\$(date): vLLM did not become healthy after restart" >> \$LOG
    return 1
}

while true; do
    # Container liveness
    if ! docker ps --format '{{.Names}}' | grep -q '^vllm-b70\$'; then
        echo "\$(date): Container down, restarting docker service..." >> \$LOG
        sudo systemctl restart vllm-docker 2>>\$LOG || true
        sleep 15
        restart_vllm
        sleep 30
        continue
    fi

    # HTTP health probe — the authoritative check
    if curl -sf --max-time 3 "\$HEALTH_URL" >/dev/null 2>&1; then
        CONSECUTIVE_FAILURES=0
    else
        CONSECUTIVE_FAILURES=\$((CONSECUTIVE_FAILURES + 1))
        echo "\$(date): Health check failed (\$CONSECUTIVE_FAILURES/\$FAILURE_THRESHOLD)" >> \$LOG
        if [ \$CONSECUTIVE_FAILURES -ge \$FAILURE_THRESHOLD ]; then
            restart_vllm
        fi
    fi
    sleep 30
done
WATCHEOF
chmod +x "${REAL_HOME}/watchdog_vllm.sh"
chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/watchdog_vllm.sh"

# --- Systemd service for vLLM watchdog ---
cat > /etc/systemd/system/vllm-watchdog.service << EOF
[Unit]
Description=vLLM Watchdog — auto-restart on crash (ODIN)
After=docker.service vllm-docker.service
Wants=docker.service

[Service]
Type=simple
User=${REAL_USER}
ExecStart=${REAL_HOME}/watchdog_vllm.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- VRAM cleanup helper (pre-start hook) ---
# Reclaims VRAM held by crashed vLLM workers before re-launching the model.
# Prevents level_zero UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY on dirty restarts.
CLEANUP_SCRIPT_PATH="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/vllm_vram_cleanup.sh"
if [[ -f "\$CLEANUP_SCRIPT_PATH" ]]; then
    install -m755 "\$CLEANUP_SCRIPT_PATH" /usr/local/bin/vllm_vram_cleanup.sh
else
    curl -fsSL https://raw.githubusercontent.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server/master/vllm_vram_cleanup.sh \
        -o /usr/local/bin/vllm_vram_cleanup.sh
    chmod 755 /usr/local/bin/vllm_vram_cleanup.sh
fi

# --- xe driver tuning (runs before vllm-docker at every boot) ---
# Raises per-engine job_timeout_ms / preempt_timeout_us to the engine max and
# pins GT frequency to disable DVFS. Root cause fix for the xe GuC watchdog
# hang (xe_guc_submit.c:1291 guc_exec_queue_timedout_job) seen on Gemma 4
# 26B-A4B FP8 TP=4 enforce_eager workloads where a single compute submission
# can exceed the 5000 ms default timeout.
XE_TUNING_SRC="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/xe_tuning.sh"
if [[ -f "\$XE_TUNING_SRC" ]]; then
    install -m755 "\$XE_TUNING_SRC" /usr/local/bin/xe_tuning.sh
fi
XE_TMPFILES_SRC="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/tmpfiles.d/xe-gpu-tuning.conf"
if [[ -f "\$XE_TMPFILES_SRC" ]]; then
    install -m644 "\$XE_TMPFILES_SRC" /etc/tmpfiles.d/xe-gpu-tuning.conf
fi
XE_UNIT_SRC="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/systemd/xe-tuning.service"
if [[ -f "\$XE_UNIT_SRC" ]]; then
    install -m644 "\$XE_UNIT_SRC" /etc/systemd/system/xe-tuning.service
    systemctl daemon-reload
    systemctl enable xe-tuning.service
fi

# --- Systemd service for vLLM serve (with graceful stop) ---
cat > /etc/systemd/system/vllm-serve.service << EOF
[Unit]
Description=vLLM Model Server (inside Docker container)
After=vllm-docker.service
Requires=vllm-docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStopSec=60
# Reclaim VRAM from any crashed workers before (re)starting vLLM.
# Defense-in-depth against level_zero UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY
# on dirty restarts after xe GuC job timeouts.
ExecStartPre=/usr/local/bin/vllm_vram_cleanup.sh
ExecStartPre=/bin/sleep 10
ExecStart=${REAL_HOME}/start_vllm.sh
ExecStop=${REAL_HOME}/stop_vllm.sh
# Health check: wait up to 5 min for vLLM to respond
ExecStartPost=/bin/bash -c 'for i in \$(seq 1 60); do curl -s http://127.0.0.1:${VLLM_PORT}/health && exit 0; sleep 5; done; echo "vLLM health timeout"'

[Install]
WantedBy=multi-user.target
EOF

# --- GPU diagnostic logger ---
# Captures comprehensive GPU and inference state to /var/log/gpu-diag/ so
# intermittent issues (PCODE timeouts, xe driver init failures, oneCCL hangs,
# vLLM EngineCore RPC timeouts) can be debugged after the fact. Reads dmesg,
# /sys/class/drm, /sys/bus/pci, igsc, and the vLLM /health endpoint. Runs at
# boot, every 5 minutes via systemd timer, and is hooked into the vLLM
# watchdog's restart_vllm() function so a snapshot is captured at the
# moment of failure.
#
# Files in /var/log/gpu-diag/:
#   state.log         one-line per snapshot (lightweight, append-only)
#   events.log        state-transition events (card count change, vllm down)
#   detail-YYYY-MM-DD.log   per-day full detail dump (rotated after 14 days)
#   dmesg-last.txt    full dmesg snapshot at the most recent failure
SCRIPT_PATH="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/gpu_diag_logger.sh"
if [[ -f "\$SCRIPT_PATH" ]]; then
    install -m755 "\$SCRIPT_PATH" /usr/local/bin/gpu_diag_logger.sh
else
    # Fallback: install from GitHub raw URL if running odin-b70-setup.sh standalone
    curl -fsSL https://raw.githubusercontent.com/Hal9000AIML/arc-pro-b70-inference-setup/master/gpu_diag_logger.sh \
        -o /usr/local/bin/gpu_diag_logger.sh
    chmod 755 /usr/local/bin/gpu_diag_logger.sh
fi
mkdir -p /var/log/gpu-diag

cat > /etc/systemd/system/gpu-diag-boot.service << EOF
[Unit]
Description=GPU diagnostic snapshot at boot
After=multi-user.target gpu-rescan.service vllm-docker.service
Wants=gpu-rescan.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpu_diag_logger.sh --boot
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/gpu-diag-timer.service << EOF
[Unit]
Description=GPU diagnostic snapshot (timer-driven)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpu_diag_logger.sh
EOF

cat > /etc/systemd/system/gpu-diag-timer.timer << EOF
[Unit]
Description=Run GPU diagnostic snapshot every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=gpu-diag-timer.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable vllm-docker.service
systemctl enable vllm-serve.service
systemctl enable gpu-thermal-watchdog.service
systemctl enable vllm-watchdog.service
systemctl enable gpu-diag-boot.service
systemctl enable gpu-diag-timer.timer

# Intel driver/firmware daily update checker
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SETUP_DIR/intel_update_check.sh" ]]; then
    install -m 0755 "$SETUP_DIR/intel_update_check.sh" /usr/local/bin/intel_update_check.sh
    install -m 0644 "$SETUP_DIR/systemd/intel-update-check.service" /etc/systemd/system/intel-update-check.service
    install -m 0644 "$SETUP_DIR/systemd/intel-update-check.timer" /etc/systemd/system/intel-update-check.timer
    systemctl daemon-reload
    systemctl enable --now intel-update-check.timer
    echo "    Intel update checker installed + enabled."
fi

echo "    Done."

# -----------------------------------------------------------
# 9b. Inference diagnostic logger + LAN health HTTP endpoint
# -----------------------------------------------------------
# This installs a 60s JSONL sampler, a port-8765 HTTP endpoint that serves the
# latest sample (so the main PC can check box health without SSH — crucial
# when sshd wedges under swap pressure), and a boot-forensics capture service.
# All units are OOM-protected with OOMScoreAdjust=-500.
echo ""
echo ">>> [9b] Installing inference diagnostic logger + LAN health endpoint"
DIAG_INSTALLER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_inference_diag.sh"
if [[ -f "$DIAG_INSTALLER" ]]; then
    bash "$DIAG_INSTALLER" || echo "    WARN: inference diag install reported a problem (continuing)"
else
    echo "    WARN: $DIAG_INSTALLER not found — skipping (re-run install_inference_diag.sh manually)"
fi

# -----------------------------------------------------------
# 10. Firewall & monitoring tools
# -----------------------------------------------------------
echo ""
echo ">>> [10/11] Firewall & monitoring"

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp comment "SSH" 2>/dev/null
    ufw allow "${VLLM_PORT}/tcp" comment "vLLM API" 2>/dev/null
    ufw allow "${LLAMACPP_PORT}/tcp" comment "llama.cpp" 2>/dev/null
    ufw allow from 192.168.1.0/24 to any port 8765 proto tcp comment "inference diag HTTP" 2>/dev/null
    ufw --force enable 2>/dev/null
    echo "    Firewall: ports 22, ${VLLM_PORT}, ${LLAMACPP_PORT}, 8765 (LAN) open"
fi

# Install xpu-smi
echo "    Installing xpu-smi..."
XPUSMI_URL=$(curl -s https://api.github.com/repos/intel/xpumanager/releases/latest 2>/dev/null | \
    python3 -c "import json,sys; [print(a['browser_download_url']) for a in json.load(sys.stdin).get('assets',[]) if 'u24' in a['name'] and a['name'].endswith('.deb')]" 2>/dev/null | head -1)
if [[ -n "$XPUSMI_URL" && "$XPUSMI_URL" == https://github.com/intel/xpumanager/* ]]; then
    XPUSMI_TMP=$(mktemp)
    wget -q "$XPUSMI_URL" -O "$XPUSMI_TMP"
    if file "$XPUSMI_TMP" | grep -q "Debian binary package"; then
        dpkg -i "$XPUSMI_TMP" 2>/dev/null || apt-get install -f -y -qq 2>/dev/null
        echo "    xpu-smi installed"
    else
        echo "    WARNING: Downloaded xpu-smi is not a valid .deb package"
    fi
    rm -f "$XPUSMI_TMP"
else
    echo "    WARNING: Could not find xpu-smi release. Install manually from github.com/intel/xpumanager/releases"
fi

echo "    Done."

# -----------------------------------------------------------
# 11. Summary
# -----------------------------------------------------------
echo ""
echo "================================================================"
echo "Intel B70 Setup Complete!"
echo "================================================================"
echo ""
echo "System:"
echo "  User:     ${REAL_USER}"
echo "  Kernel:   $(uname -r)${NEED_REBOOT:+ (NEW KERNEL INSTALLED — REBOOT REQUIRED)}"
echo "  GPUs:     ${B70_COUNT}x Intel Arc Pro B70"
echo "  Docker:   ${VLLM_DOCKER_IMAGE}"
echo "  Model:    ${VLLM_MODEL} at ${MODEL_PATH}"
echo ""
echo "Scripts:"
echo "  ~/boot_vllm.sh        — Start everything (container + vLLM server)"
echo "  ~/start_vllm.sh       — Start vLLM inside existing container"
echo "  ~/start_llamacpp.sh   — Start llama.cpp Vulkan (single-GPU fallback)"
echo "  ~/sysinfo.sh          — Show system status"
echo ""
echo "Auto-recovery (survives reboots and crashes):"
echo "  vllm-docker.service   — Auto-starts container on boot"
echo "  vllm-watchdog.service — Monitors and restarts vLLM if it crashes"
echo "  gpu-thermal-watchdog  — Stops vLLM if GPU temp exceeds 90C"
echo ""
echo "After boot:"
echo "  API endpoint:  http://$(hostname -I | awk '{print $1}'):${VLLM_PORT}"
echo "  Health check:  curl http://$(hostname -I | awk '{print $1}'):${VLLM_PORT}/health"
echo ""
echo "Test:"
echo "  curl http://$(hostname -I | awk '{print $1}'):${VLLM_PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${VLLM_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100}'"
echo ""

if [[ "${NEED_REBOOT}" == "true" ]]; then
    echo "================================================================"
    echo "  REBOOT REQUIRED for new kernel and GRUB parameters!"
    echo "  Run: sudo reboot"
    echo "  Then: ~/boot_vllm.sh"
    echo "================================================================"
fi

echo ""
echo "Performance targets (4x B70, Gemma 4 26B-A4B BF16, TP=4):"
echo "  Single request:   ~25-35 tok/s (with 128GB RAM)"
echo "  8 concurrent:     ~160-220 tok/s"
echo "  128 concurrent:   ~480-540 tok/s (requires --max-num-seqs 128)"
echo ""
echo "Performance targets (4x B70, Gemma 4 26B-A4B BF16, TP=4, 16GB RAM + swap):"
echo "  Single request:   ~5.7 tok/s (swap-bottlenecked)"
echo "  8 concurrent:     ~37 tok/s"
echo "  NOTE: Upgrade to 128GB DDR4-3200 for full performance"
echo ""
echo "GPU temps under load: 61-67C package, 62-68C VRAM (well within limits)"
echo ""
echo "Log saved to: ${LOG}"
