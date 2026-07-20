# Vendored RNNoise

Noise-suppression engine used by `AudioEnhancementPipeline` / `RNNoiseEngine`
(the "Voice Cleanup" feature). See `docs/editing-platform-plan.md` Phase 4.

- **Upstream:** https://github.com/xiph/rnnoise
- **Version:** v0.2 release tarball (`rnnoise-0.2.tar.gz`,
  sha256 `90fce4b00b9ff24c08dbfe31b82ffd43bae383d85c5535676d28b0a2b11c0d37`).
  The release tarball is used (not a git checkout) because it ships the
  pre-generated model weights (`rnnoise_data.c`).
- **License:** BSD-3-Clause — see `COPYING` in this directory. The repo's
  GPLv3 is compatible; the notice ships with the sources.

## What is vendored

Only the library itself, flattened from the tarball's `include/` + `src/`:
the 10 sources of upstream's `RNNOISE_SOURCES` (Makefile.am) plus the headers
they include. The tooling sources (`dump_features.c`, `write_weights.c`), the
x86 runtime-dispatch sources (`x86/*.c`, only used with `RNN_ENABLE_X86_RTCD`,
which we do not define), and the autotools build system are omitted.
`x86/x86_arch_macros.h` is kept because `vec.h` includes it unconditionally.

Compiled with no extra defines: `HAVE_CONFIG_H` unset (no `config.h`),
no x86 RTCD. SIMD still engages per-arch at compile time via `vec.h`
(`vec_neon.h` on arm64, `vec_avx.h` on x86_64).

## Local modifications

One packaging bug in the 0.2 tarball is patched, mirroring upstream `main`:
`vec.h` / `vec_neon.h` included `os_support.h`, a file that does not exist
anywhere in the tarball or upstream. Per the upstream fix, the includes were
replaced with `opus_types.h` + `common.h` (`vec_neon.h`) and dropped from the
never-simd fallback branch (`vec.h`).

Do not edit these sources otherwise. To upgrade: fetch the new release
tarball, re-flatten the same file set, re-check whether the os_support patch
is still needed, and bump `RNNoiseEngine.engineVersion` so cached denoised
audio is invalidated.
