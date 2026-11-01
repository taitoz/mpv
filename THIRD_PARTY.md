# Third-party components

This repository bundles third-party mpv scripts, shaders, fonts and resources.
Each file remains under its own license, as declared in its header and by the
upstream project. The list below is provided for attribution; upstream licenses
take precedence over this document.

## Scripts

| Component | Path | Upstream | License |
| --- | --- | --- | --- |
| uosc | `scripts/uosc/` | github.com/tomasklaen/uosc | LGPL-2.1 |
| uosc fonts (icons/textures) | `fonts/uosc_*` | github.com/tomasklaen/uosc | LGPL-2.1 |
| thumbfast | `scripts/thumbfast.lua` | github.com/po5/thumbfast | MPL-2.0 |
| memo | `scripts/memo.lua` | github.com/po5/memo | GPL-3.0 |
| quality-menu | `scripts/quality-menu.lua` | github.com/christoph-heinrich/mpv-quality-menu | GPL-2.0 |
| evafast | `scripts/evafast.lua` | github.com/po5/evafast | no license declared upstream; verify before reuse |
| sponsorblock_minimal | `scripts/sponsorblock_minimal.lua` | uosc extras / github.com/ajayyy/SponsorBlock data | LGPL-2.1 (bundled with uosc) |
| reload | `scripts/reload.lua` | third-party mpv script, upstream to verify | unverified |
| ytsub | `scripts/ytsub.lua` | third-party mpv script, upstream to verify | unverified |
| cycle-commands | `scripts/cycle-commands.lua` | third-party mpv script, upstream to verify | unverified |
| custom-scripts | `scripts/custom-scripts.lua` | third-party mpv script, upstream to verify | unverified |

## Shaders

| Component | Path | Upstream | License |
| --- | --- | --- | --- |
| Anime4K | `shaders/Anime4K/` | github.com/bloc97/Anime4K | MIT |
| ArtCNN / Ani4Kv2 / AniSD | `shaders/ArtCNN/`, `shaders/Ani4Kv2 and AniSD/` | github.com/Artoriuz/ArtCNN | MIT |
| ACNet | `shaders/ACNet/` | github.com/TianZerL/ACNetGLSL | MIT |
| AMD/NVIDIA (CAS, FSR, NVSharpen, NVScaler) | `shaders/AMD and Nvidia/` | AMD / NVIDIA GPUOpen | MIT |
| Chroma (CfL_Prediction, bilaterals) | `shaders/Chroma/` | github.com/Artoriuz/ArtCNN + mpv community | MIT |
| FSRCNNX | `shaders/FSRCNNX/` | github.com/igv/FSRCNN-TensorFlow | GPL-3.0 |
| SSim / SSSR / SSimSuperRes / SSimDownscaler | `shaders/SSim/` | github.com/bjin/mpv-prescalers + igv | LGPL-3.0+ |
| CuNNy | `shaders/CuNNy/` | github.com/funnyplanter/CuNNy | LGPL-3.0 |
| NNEDI3 | `shaders/NNEDI3/` | mpv-prescalers / vapoursynth-nnedi3 port | LGPL-3.0+ |
| RAVU | `shaders/RAVU/` | github.com/bjin/mpv-prescalers | LGPL-3.0+ |
| nlmeans | `shaders/nlmeans.glsl` | github.com/an3223/dotfiles | MIT |
| hdeband | `shaders/hdeband.glsl` | github.com/an3223/dotfiles | LGPL-3.0+ |
| adaptive-sharpen | `shaders/adaptive-sharpen.glsl` | bacondither | BSD 2-clause |
| film-grain | `shaders/Film grain/` | mpv community shader | unverified; see file header |
| vr-flat | `shaders/vr-flat.glsl` | this repository | GPL-3.0 |

## Notes

- Most GLSL/Lua files carry their original copyright and license headers —
  those headers are the authoritative attribution and must be preserved.
- Components marked "unverified" or "no license declared" lack an explicit
  upstream license; treat them as all-rights-reserved until confirmed or
  replaced with an alternative under a clear license.
- mpv itself (GPL-2.0+/LGPL-2.1+ player binary) is not distributed by this
  repository; only configuration files compatible with it are.
- Personal fonts (Netflix Sans, TX-02) are git-ignored and not distributed.
