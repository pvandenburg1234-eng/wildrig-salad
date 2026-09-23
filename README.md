# Quai (KawPow) GPU miner container for SaladCloud — AMD GPUs

Container image for SaladCloud AMD GPU classes (RX 6000 / RX 7000) that mines
Quai over KawPow. It bundles three miners and auto-selects the first one that
produces an accepted share on the node it lands on:

1. [TeamRedMiner](https://github.com/todxx/teamredminer) — AMD-only, precompiled
   kernels, KawPow supported on RDNA3 under ROCm drivers (2% devfee) —
   **verified working on SaladCloud RX 7900 XT, 2026-09-22 (image tag `v6`)**
2. [SRBMiner-MULTI](https://github.com/doktor83/SRBMiner-Multi) (0.85% devfee)
3. [WildRig-Multi](https://github.com/andru-kun/wildrig-multi) — last resort;
   under ROCm's OpenCL its ProgPoW kernel either fails to build or runs with
   `CL_INVALID_ARG_INDEX` and never hashes (0.75% devfee)

**Read the economics note in `Dockerfile` first.** Renting GPUs to mine is usually
a net loss; test with one replica for 24 h before scaling.

## 1. Get the image built (no Docker needed)

1. Create a free GitHub account if you don't have one, then create a new
   **public** repository (e.g. `wildrig-salad`).
2. From this folder, in PowerShell:

   ```powershell
   git remote add origin https://github.com/<YOU>/wildrig-salad.git
   git push -u origin main
   ```

3. On GitHub open the **Actions** tab — the `build-and-push` workflow runs
   automatically (~5–10 min) and pushes `ghcr.io/<you>/wildrig-salad:latest`.
4. Make the package public: your GitHub profile → **Packages** →
   `wildrig-salad` → **Package settings** → **Change visibility** → Public.
   SaladCloud can only pull public images (or you'd have to configure registry
   credentials in the container group).

## 2. Get a Quai wallet address

Install the [Pelagus](https://pelaguswallet.io/) browser wallet, create a
wallet, and copy the **Cyprus-1** zone address (starts with `0x00`). Pools
require a Cyprus-1 address for payouts.

## 3. Deploy on SaladCloud

Portal → **Container Groups → Deploy**:

| Setting | Value |
|---|---|
| Image | `ghcr.io/<you>/wildrig-salad:vN` — use the `vN` tag printed by the Actions run, **not `:latest`**. Salad caches images by tag and will not re-pull `:latest` after you push a change; a new `vN` tag is what rolls out an update. |
| Replicas | `1` for testing |
| GPU | an **AMD** class. Verified: RX 7800 XT (37 MH/s), 7900 XT (45 MH/s), 7900 XTX (54 MH/s). RX 9060 XT (18 MH/s, via SRBMiner). RX 9070 XT should work the same way (unverified). Don't put NVIDIA classes in the same group. |
| vCPU / RAM | 2 vCPU / 4 GB |
| Storage | smallest |
| Priority | Batch |
| Command | *(leave empty)* |
| Gateway / health probes | none / off |

Environment variables:

| Name | Value |
|---|---|
| `WALLET` | your Cyprus-1 address (`0x00…`) — **required** |
| `POOL` | `stratum+tcp://ca.quai.herominers.com:1185` (default). For HeroMiners the **region is auto-selected** at startup by TCP latency from the node (`ca us de fi fr hk sg kr au br tr ru`); the log shows the probe results. Set `POOL_AUTO=0` to use `POOL` exactly as given. |
| `ALGO` | `kawpow` (default) |
| `WORKER` | optional label; Salad's machine id is used if unset |
| `MINERS` | order to try. Auto-detected from GPU arch: `trm srb wildrig` on RDNA2/3 (RX 6000/7000), `srb wildrig` on RDNA4 (RX 9070/9060 — TeamRedMiner predates RDNA4). Pin one with e.g. `MINERS=trm` |
| `NO_SHARE_TIMEOUT` | seconds a miner gets to produce an accepted share before the next is tried (default `300`) |
| `TRM_EXTRA_ARGS` / `SRB_EXTRA_ARGS` / `WILDRIG_EXTRA_ARGS` | optional extra flags per miner |

## 4. Verify

Open the container's logs in the Salad portal. You should see:

1. `rocminfo` listing an agent with a `gfx…` name (GPU visible).
2. `clinfo -l` showing an AMD platform.
3. `=== [trm] starting ...` then, within a few minutes,
   `=== [trm] ACCEPTED SHARE - this miner works on this node ===`.

Then check `https://quai.herominers.com/` with your wallet address to see
hashrate and estimated earnings; compare that to what Salad bills per hour.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HSA_STATUS_ERROR_OUT_OF_RESOURCES` in rocminfo | Image ROCm < 7.1 or something overwrote `LD_LIBRARY_PATH`. Don't set those in Dockerfile/entrypoint. |
| `no accepted share after 300s - killing and trying next miner` | That miner can't hash on this node's driver stack; the entrypoint moves on. Once you see `ACCEPTED SHARE - this miner works`, pin it with `MINERS=<name>` to skip the probing on future reallocations. |
| WildRig: `CL_BUILD_PROGRAM_FAILURE` / `CL_INVALID_ARG_INDEX ... kawpow_phase3` | Expected under ROCm OpenCL — WildRig targets AMD's proprietary driver. That's why it's last in the list. |
| `no OpenCL devices found` but rocminfo works | OpenCL ICD missing — check `/etc/OpenCL/vendors/amdocl64.icd` exists and points to a real `libamdocl64.so`. |
| `share rejected ... Job expired`, pool latency > ~150 ms | Node is far from the pool region. With `POOL_AUTO=1` (default) the entrypoint picks the nearest HeroMiners region; check the `Probing HeroMiners regions` lines. |
| Instance keeps restarting | Batch priority nodes get reallocated; that's normal. Check for `ERROR: set the WALLET` in logs. |
| Works locally, fails on Salad | Salad's AMD path is ROCm-on-WSL, not native ROCm; only test on Salad. |

## Files

- `Dockerfile` — image definition (ROCm 7.2 base + TeamRedMiner, SRBMiner, WildRig)
- `entrypoint.sh` — readiness checks + miner selection by accepted shares
- `.github/workflows/build.yml` — builds and pushes to GHCR on every push to `main`
