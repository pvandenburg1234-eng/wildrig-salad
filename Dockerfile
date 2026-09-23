# ============================================================================
#  Quai (KawPow) GPU miner for SaladCloud  (AMD GPU classes, ROCm-on-WSL / DXG)
#
#  Ships THREE miners and lets the entrypoint pick the first one that actually
#  produces accepted shares on the node it lands on:
#    1. TeamRedMiner  (AMD-only, precompiled kernels, KawPow on RDNA3 + ROCm)
#    2. SRBMiner-MULTI
#    3. WildRig-Multi (known NOT to hash under ROCm OpenCL - kept as last resort)
#
#  How AMD GPUs work on SaladCloud (per Salad's AMD/ROCm docs):
#    * The GPU is /dev/dxg (WSL bridge). There is NO /dev/kfd or /dev/dri.
#    * The host injects librocdxg (/opt/rocm-host/lib), the WSL driver libs
#      (/usr/lib/wsl/lib) and a DXG-capable amd-smi (/opt/rocm-wsl), and sets
#      HSA_ENABLE_DXG_DETECTION=1 plus the LD_LIBRARY_PATH / PATH ordering.
#    * The host does NOT provide a ROCm runtime - the image must ship ROCm
#      7.1 or newer. Anything older fails with HSA_STATUS_ERROR_OUT_OF_RESOURCES.
#    * NEVER assign LD_LIBRARY_PATH / PYTHONPATH in the image or entrypoint -
#      that erases the injected bridge and the GPU disappears.
#    * `rocminfo` is the official readiness check; the entrypoint runs it first.
#
#  ---- BUILD & PUSH ---------------------------------------------------------
#  No Docker locally? Push this folder to a GitHub repo - the included
#  .github/workflows/build.yml builds and pushes ghcr.io/<you>/wildrig-salad
#  automatically (see README.md).  With Docker:
#    docker build -t YOURUSER/wildrig-salad:latest .
#    docker push  YOURUSER/wildrig-salad:latest
#
#  ---- SaladCloud container-group settings ----------------------------------
#    Image Name : ghcr.io/<you>/wildrig-salad:vN  (PUBLIC image; use the vN tag
#                 from the Actions run - Salad won't re-pull a changed :latest)
#    Replicas   : 1   (for testing)
#    GPU        : an AMD class (RX 7000 / RX 6000). Do NOT mix with NVIDIA.
#    vCPU / RAM : 2 vCPU / 4 GB   (KawPow is GPU-bound - don't overbuy)
#    Storage    : minimum
#    Priority   : Batch (cheapest, interruptible - fine for mining)
#    Command    : leave EMPTY (the ENTRYPOINT below runs the miner)
#    Gateway    : none        Health probe : OFF
#    Environment Variables:
#      WALLET = <your payout address>            (REQUIRED)
#      POOL   = <pool host:port>                 (see options below)
#      ALGO   = kawpow (Quai)
#      MINERS = optional; auto = "trm srb wildrig" (RDNA2/3) or "srb wildrig" (RDNA4)
#      WORKER = optional; Salad's machine id is used automatically if unset
#
#  ---- POOL options ---------------------------------------------------------
#    Quai (KawPow) - HeroMiners (region auto-selected by latency at startup;
#    regions: ca us de fi fr hk sg kr au br tr ru; set POOL_AUTO=0 to pin):
#      POOL   = stratum+tcp://ca.quai.herominers.com:1185
#      WALLET = your Pelagus Cyprus-1 zone address (0x00... )
#    Quai (KawPow) - 2Miners (alternative):
#      POOL   = stratum+tcp://quai-kawpow.2miners.com:5555  (check 2miners.com for region ports)
#
#  ---- HONEST NOTE ON ECONOMICS ---------------------------------------------
#    On public SaladCloud rental prices, renting a GPU to mine generally LOSES
#    money (rent >= coin yield). Treat this as a test. Deploy ONE replica for
#    24h and compare the pool's estimated daily earnings to the all-in $/hr
#    Salad bills you BEFORE scaling replicas.
# ============================================================================

# Salad-recommended AMD base (ROCm 7.2, ubuntu 24.04). Includes rocminfo.
FROM rocm/dev-ubuntu-24.04:7.2

ENV DEBIAN_FRONTEND=noninteractive

# OpenCL runtime + ICD loader so the miners can see the AMD platform.
# Package name differs across ROCm releases, so try both. The ROCm package can
# register the AMD platform twice (two .icd files); keep exactly one so the
# GPU isn't enumerated twice.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget curl ocl-icd-libopencl1 clinfo procps \
    && (apt-get install -y --no-install-recommends rocm-opencl-runtime \
        || apt-get install -y --no-install-recommends rocm-opencl) \
    && mkdir -p /etc/OpenCL/vendors \
    && (ls /etc/OpenCL/vendors/amdocl64.icd >/dev/null 2>&1 \
        || echo "/opt/rocm/lib/libamdocl64.so" > /etc/OpenCL/vendors/amdocl64.icd) \
    && rm -rf /var/lib/apt/lists/* \
    && for f in /etc/OpenCL/vendors/*; do [ "$f" = /etc/OpenCL/vendors/amdocl64.icd ] || rm -f "$f"; done \
    && ls -la /etc/OpenCL/vendors && cat /etc/OpenCL/vendors/*

# --- 1. TeamRedMiner --------------------------------------------------------
ARG TRM_VERSION=0.10.21
RUN wget -qO /tmp/trm.tgz \
      https://github.com/todxx/teamredminer/releases/download/v${TRM_VERSION}/teamredminer-v${TRM_VERSION}-linux.tgz \
 && mkdir -p /opt/trm \
 && tar xzf /tmp/trm.tgz -C /opt/trm --strip-components=1 \
 && rm /tmp/trm.tgz \
 && chmod +x /opt/trm/teamredminer

# --- 2. SRBMiner-MULTI ------------------------------------------------------
ARG SRB_VERSION=3.6.9
RUN wget -qO /tmp/srb.tgz \
      https://github.com/doktor83/SRBMiner-Multi/releases/download/${SRB_VERSION}/SRBMiner-Multi-$(echo ${SRB_VERSION} | tr . -)-Linux.tar.gz \
 && mkdir -p /opt/srb \
 && tar xzf /tmp/srb.tgz -C /opt/srb --strip-components=1 \
 && rm /tmp/srb.tgz \
 && chmod +x /opt/srb/SRBMiner-MULTI

# --- 3. WildRig-Multi (last resort) ----------------------------------------
ARG WILDRIG_VERSION=0.51.2
RUN wget -qO /tmp/w.tgz \
      https://github.com/andru-kun/wildrig-multi/releases/download/${WILDRIG_VERSION}/wildrig-multi-linux-${WILDRIG_VERSION}.tar.gz \
 && mkdir -p /opt/wildrig \
 && tar xzf /tmp/w.tgz -C /opt/wildrig \
 && rm /tmp/w.tgz \
 && chmod +x /opt/wildrig/wildrig-multi

# NOTE: no LD_LIBRARY_PATH / HSA_ENABLE_DXG_DETECTION here on purpose -
# SaladCloud injects them; setting them in the image breaks GPU enumeration.

# Runtime defaults - override these in the SaladCloud env vars
ENV ALGO=kawpow \
    POOL=stratum+tcp://ca.quai.herominers.com:1185 \
    WALLET=REPLACE_WITH_YOUR_WALLET \
    WORKER=salad01 \
    NO_SHARE_TIMEOUT=300
# MINERS is intentionally NOT defaulted here: the entrypoint picks the order
# from the GPU arch (trm first on RDNA2/3, srb first on RDNA4). Set it in the
# Salad env vars only to pin a specific miner.

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
