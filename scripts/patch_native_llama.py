#!/usr/bin/env python3
"""Make native_llama 1.0.1 build on Android — with GPU acceleration when possible.

## Background

`native_llama` vendors a complete `ggml-vulkan` backend (153 compute shaders plus
the `vulkan-shaders-gen` host tool that turns them into SPIR-V blobs at build
time). Two things stop that backend from working out of the box:

1.  `android/build.gradle.kts` hard-codes `-DGGML_USE_VULKAN=1` in `cppFlags`, so
    `ggml-backend-reg.cpp` compiles a `register_backend(ggml_backend_vk_reg())`
    call. If the Vulkan backend is not actually linked, the result is

        ld.lld: error: undefined symbol: ggml_backend_vk_reg

2.  `ggml-vulkan/CMakeLists.txt` opens with

        find_package(Vulkan COMPONENTS glslc REQUIRED)

    `glslc` is the GLSL→SPIR-V shader compiler. Without it the backend target is
    never created, and the flash-attention kernels it references — which exist
    only as *generated* SPIR-V blobs, e.g. `flash_attn_f32_f16_f32_data` — stay
    undefined, giving the second confusing link error.

Both failures have the same single cause: **glslc is missing**. So this script
does not blanket-disable Vulkan; it decides based on whether the shader compiler
is actually available.

## Modes

*   **glslc found** — leave the Gradle define `-DGGML_USE_VULKAN=1` in place,
    force `GGML_VULKAN ON`, and guard the `target_include_directories` call so it
    only runs when the target exists. The APK then ships GPU support.

    This is safe to distribute broadly: `ggml_backend_load_all()` registers the
    Vulkan backend only if a usable Vulkan device is found, and llama.cpp falls
    back to the CPU otherwise. A phone with no Vulkan driver — or with a broken
    one — simply runs on the CPU. That runtime fallback is what lets a single
    APK serve "almost all phones" rather than needing per-GPU builds.

*   **glslc missing** — strip the Gradle define and force `GGML_VULKAN OFF`, so
    the app builds CPU-only instead of failing to link.

Usage:
    python3 scripts/patch_native_llama.py            # CPU-only (Clawzilla default)
    python3 scripts/patch_native_llama.py --gpu      # re-enable Vulkan if glslc is present
    python3 scripts/patch_native_llama.py --cpu      # force CPU-only (same as default)
    python3 scripts/patch_native_llama.py --require-gpu  # fail if glslc absent

## MiniCPM5 tokenizer

native_llama 1.0.1's vendored llama.cpp predates MiniCPM5 (Sept 2026), so its
BPE pre-tokenizer list has no "minicpm5" entry and loading a MiniCPM5 GGUF
throws "unknown pre-tokenizer type: 'minicpm5'" before any weight is touched.
This script also mirrors the upstream llama.cpp MiniCPM5 support into the
vendored tree (enum entry, pre-tokenizer regexes, and the "minicpm5" mapping
with ignore_merges / clean_spaces flags) so those models load.

## Engine update

native_llama 1.0.1's vendored llama.cpp is from April 2026. It predates
MiniCPM5, Qwen3.5 and other current models, so every new model family needed
a hand-written patch (MiniCPM5 above) or refused to load at all. This script
also swaps the whole vendored tree for a pinned current llama.cpp snapshot
(LLAMA_CPP_COMMIT), so a new GGUF loads without a per-model line. The commit
is pinned so builds are reproducible; bump it to move to a newer engine.

The swap is done at build time (the CI downloads the tarball and replaces
ios/shared_cpp with the same subset native_llama vendors), so the fork stays
small. On the new tree the MiniCPM5 vocab patch above is a no-op — the tree
already knows "minicpm5" — and it is kept so the script still fixes the
stock April 2026 tree if the engine update is ever skipped. The one file the
new tree dropped that the plugin's CMakeLists lists explicitly,
tools/mtmd/clip.cpp, is removed from that list as part of the swap.
"""

from __future__ import annotations

import os
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------- CMakeLists

CMAKE_VULKAN_ON = 'set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan" FORCE)'

CMAKE_VULKAN_OFF = (
    'set(GGML_VULKAN OFF CACHE BOOL '
    '"off: no glslc shader compiler on this host" FORCE)'
)

CMAKE_INCLUDE_BLOCK = """target_include_directories(ggml-vulkan PRIVATE
    "${vulkanheaders_SOURCE_DIR}/include"
    "${spirvheaders_SOURCE_DIR}/include"
)"""

CMAKE_GUARDED_BLOCK = """if(TARGET ggml-vulkan)
    target_include_directories(ggml-vulkan PRIVATE
        "${vulkanheaders_SOURCE_DIR}/include"
        "${spirvheaders_SOURCE_DIR}/include"
    )
endif()"""

# ------------------------------------------------------------- build.gradle

GRADLE_FLAG = "-DGGML_USE_VULKAN=1"


def glslc_path() -> str | None:
    """Locate glslc, including inside a LunarG Vulkan SDK if one is present."""
    found = shutil.which("glslc")
    if found:
        return found

    for var in ("VULKAN_SDK", "VULKAN_SDK_ROOT"):
        root = os.environ.get(var)
        if root:
            candidate = Path(root) / "bin" / "glslc"
            if candidate.is_file():
                return str(candidate)

    # Common install locations used by the distro package.
    for candidate in (
        Path("/usr/bin/glslc"),
        Path("/usr/local/bin/glslc"),
    ):
        if candidate.is_file():
            return str(candidate)

    return None


def patch_cmake(path: Path, enable_gpu: bool) -> bool:
    original = text = path.read_text()

    if enable_gpu:
        if CMAKE_VULKAN_OFF in text:
            text = text.replace(CMAKE_VULKAN_OFF, CMAKE_VULKAN_ON)
    else:
        if CMAKE_VULKAN_ON in text:
            text = text.replace(CMAKE_VULKAN_ON, CMAKE_VULKAN_OFF)

    # Guard the include-directories call either way: it is fatal when the
    # ggml-vulkan target was not created, which is exactly what happens on the
    # CPU-only path.
    if CMAKE_INCLUDE_BLOCK in text:
        text = text.replace(CMAKE_INCLUDE_BLOCK, CMAKE_GUARDED_BLOCK)
    elif "if(TARGET ggml-vulkan)" not in text:
        raise SystemExit("::error::unrecognised ggml-vulkan block in %s" % path)

    if text == original:
        return False
    path.write_text(text)
    return True


def patch_gradle(path: Path, enable_gpu: bool) -> bool:
    original = text = path.read_text()
    lines = text.splitlines(keepends=True)

    if enable_gpu:
        # The define must be present, or the backend is compiled but never
        # registered with ggml's backend registry.
        if GRADLE_FLAG in text:
            return False
        out: list[str] = []
        added = False
        for ln in lines:
            out.append(ln)
            if not added and "cppFlags" in ln:
                indent = ln[: len(ln) - len(ln.lstrip())] + "    "
                if ln.rstrip().endswith(")"):
                    out[-1] = ln.replace(")", '"%s")\n' % GRADLE_FLAG)
                else:
                    out.append('%s"%s",\n' % (indent, GRADLE_FLAG))
                added = True
        if not added:
            return False
        text = "".join(out)
    else:
        text = "".join(ln for ln in lines if GRADLE_FLAG not in ln)

    if text == original:
        return False
    path.write_text(text)
    return True


# ------------------------------------------------------- MiniCPM5 tokenizer

VOCAB_H_ANCHOR = "    LLAMA_VOCAB_PRE_TYPE_GEMMA4          = 50,\n"
VOCAB_H_INSERT = "    LLAMA_VOCAB_PRE_TYPE_MINICPM5         = 51,\n"

VOCAB_CASE_ANCHOR = (
    "                byte_encode = false; // uses raw UTF-8, not GPT-2 byte encoding\n"
    "                break;\n"
    "            default:\n"
)

# Upstream llama.cpp MINICPM5 pre-tokenizer regexes (from tokenizer.json,
# openbmb/MiniCPM5-1B). byte_encode stays true (the default) — upstream's
# MINICPM5 case does not touch it.
VOCAB_CASE_INSERT = r"""            case LLAMA_VOCAB_PRE_TYPE_MINICPM5:
                regex_exprs = {
                    // original regex from tokenizer.json (openbmb/MiniCPM5-1B)
                    "\\p{N}{1,3}",
                    // "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}+| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
                    "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}+| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+",
                };
                break;
"""

VOCAB_MAP_ANCHOR = (
    '            } else if (tokenizer_pre == "default") {\n'
    "                pre_type = LLAMA_VOCAB_PRE_TYPE_DEFAULT;\n"
    "            } else if (\n"
)

VOCAB_MAP_INSERT = (
    '            } else if (tokenizer_pre == "default") {\n'
    "                pre_type = LLAMA_VOCAB_PRE_TYPE_DEFAULT;\n"
    '            } else if (tokenizer_pre == "minicpm5") {\n'
    "                pre_type = LLAMA_VOCAB_PRE_TYPE_MINICPM5;\n"
    "                ignore_merges = true;\n"
    "                clean_spaces = false;\n"
    "            } else if (\n"
)


def patch_vocab(package_root: Path) -> int:
    """Teach the vendored llama.cpp the MiniCPM5 pre-tokenizer.

    Returns the number of files changed. Raises SystemExit if a vocab file
    is missing or an anchor no longer matches, so CI fails loudly instead
    of silently shipping an unpatched engine.
    """
    vocab_h = package_root / "ios" / "shared_cpp" / "src" / "llama-vocab.h"
    vocab_cpp = package_root / "ios" / "shared_cpp" / "src" / "llama-vocab.cpp"
    changed = 0

    if not vocab_h.is_file() or not vocab_cpp.is_file():
        raise SystemExit(
            "::error::llama-vocab.h/.cpp not found under %s; cannot apply MiniCPM5 patch"
            % package_root
        )

    text = vocab_h.read_text()
    if "LLAMA_VOCAB_PRE_TYPE_MINICPM5" not in text:
        if VOCAB_H_ANCHOR not in text:
            raise SystemExit(
                "::error::unrecognised vocab enum anchor in %s" % vocab_h
            )
        text = text.replace(VOCAB_H_ANCHOR, VOCAB_H_ANCHOR + VOCAB_H_INSERT, 1)
        vocab_h.write_text(text)
        changed += 1
        print("patched %s (added MINICPM5 enum)" % vocab_h)

    text = vocab_cpp.read_text()
    if "LLAMA_VOCAB_PRE_TYPE_MINICPM5" not in text:
        if VOCAB_CASE_ANCHOR not in text:
            raise SystemExit(
                "::error::unrecognised vocab regex anchor in %s" % vocab_cpp
            )
        text = text.replace(
            VOCAB_CASE_ANCHOR,
            "                byte_encode = false; // uses raw UTF-8, not GPT-2 byte encoding\n"
            "                break;\n"
            + VOCAB_CASE_INSERT
            + "            default:\n",
            1,
        )
        if VOCAB_MAP_ANCHOR not in text:
            raise SystemExit(
                "::error::unrecognised vocab mapping anchor in %s" % vocab_cpp
            )
        text = text.replace(VOCAB_MAP_ANCHOR, VOCAB_MAP_INSERT, 1)
        vocab_cpp.write_text(text)
        changed += 1
        print("patched %s (added MINICPM5 regex + mapping)" % vocab_cpp)

    return changed


# ------------------------------------------------------- Engine update

# Pinned llama.cpp commit (master HEAD as of 2026-11-09). Bump this to move
# to a newer engine; the commit is pinned so builds are reproducible.
LLAMA_CPP_COMMIT = "a4d4f2fd4ec85ec6a0a9ece4870416c1b6cc24f5"
LLAMA_CPP_URL = (
    "https://github.com/ggerganov/llama.cpp/archive/%s.tar.gz"
    % LLAMA_CPP_COMMIT
)

# Top-level entries copied from the new tree into ios/shared_cpp. This is the
# same subset native_llama vendors (the plugin's shared_cpp is a copy of the
# llama.cpp repo minus examples/tests/server/app). tools/ is narrowed to mtmd
# below, the only tool the plugin compiles.
ENGINE_ENTRIES = (
    "CMakeLists.txt",
    "LICENSE",
    "cmake",
    "common",
    "ggml",
    "include",
    "licenses",
    "src",
    "vendor",
)


def update_engine(package_root: Path) -> bool:
    """Replace the vendored llama.cpp with a pinned current snapshot.

    native_llama 1.0.1 vendors an April 2026 llama.cpp. That tree predates
    MiniCPM5, Qwen3.5 and other current models, so every new model family
    needed a hand-written patch or refused to load. Swapping in a current
    llama.cpp means a new GGUF loads without a per-model line.

    Returns True when the tree was replaced. Skips (returns False) when the
    tree already contains the new engine (checked by the MINICPM5 marker in
    llama-vocab.h, which the April 2026 tree lacks), so repeated runs are
    cheap. Raises SystemExit if the download or the replacement fails, so CI
    fails loudly instead of silently shipping the old engine.
    """
    shared_cpp = package_root / "ios" / "shared_cpp"
    vocab_h = shared_cpp / "src" / "llama-vocab.h"
    if vocab_h.is_file():
        try:
            if "MINICPM5" in vocab_h.read_text():
                print("engine already current (MINICPM5 present); skipping download")
                return False
        except OSError:
            pass

    print("downloading llama.cpp %s ..." % LLAMA_CPP_COMMIT)
    with tempfile.TemporaryDirectory(prefix="llama-cpp-") as tmp:
        tmp_path = Path(tmp)
        archive = tmp_path / "llama.cpp.tar.gz"
        try:
            urllib.request.urlretrieve(LLAMA_CPP_URL, archive)
        except Exception as e:  # noqa: BLE001 - report and fail loudly
            raise SystemExit(
                "::error::could not download llama.cpp %s: %s"
                % (LLAMA_CPP_COMMIT, e)
            )
        try:
            with tarfile.open(archive, "r:gz") as tf:
                tf.extractall(tmp_path)
        except Exception as e:  # noqa: BLE001 - report and fail loudly
            raise SystemExit(
                "::error::could not extract llama.cpp archive: %s" % e
            )
        roots = [p for p in tmp_path.iterdir() if p.is_dir()]
        if len(roots) != 1:
            raise SystemExit(
                "::error::unexpected llama.cpp archive layout: %s" % roots
            )
        new_root = roots[0]

        # Replace the vendored tree with the new subset. Delete first so no
        # stale April 2026 file lingers.
        if shared_cpp.exists():
            shutil.rmtree(shared_cpp)
        shared_cpp.mkdir(parents=True)
        for entry in ENGINE_ENTRIES:
            src = new_root / entry
            if not src.exists():
                raise SystemExit(
                    "::error::llama.cpp %s is missing %s; cannot update engine"
                    % (LLAMA_CPP_COMMIT, entry)
                )
            dst = shared_cpp / entry
            if src.is_dir():
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)
        # tools/ is narrowed to mtmd, the only tool the plugin compiles.
        mtmd_src = new_root / "tools" / "mtmd"
        if not mtmd_src.is_dir():
            raise SystemExit(
                "::error::llama.cpp %s is missing tools/mtmd" % LLAMA_CPP_COMMIT
            )
        shutil.copytree(mtmd_src, shared_cpp / "tools" / "mtmd")

        # The new tree dropped tools/mtmd/clip.cpp; the plugin's CMakeLists
        # lists it explicitly, so drop the line or CMake fails on a missing
        # source file. Only when the new tree really lacks it.
        if not (shared_cpp / "tools" / "mtmd" / "clip.cpp").is_file():
            cmake = (
                package_root
                / "android"
                / "src"
                / "main"
                / "cpp"
                / "CMakeLists.txt"
            )
            if cmake.is_file():
                lines = cmake.read_text().splitlines(keepends=True)
                kept = [ln for ln in lines if "tools/mtmd/clip.cpp" not in ln]
                if len(kept) != len(lines):
                    cmake.write_text("".join(kept))
                    print(
                        "dropped clip.cpp from %s (absent in new engine)"
                        % cmake
                    )

    print("engine updated to llama.cpp %s" % LLAMA_CPP_COMMIT)
    return True


# ------------------------------------------------------- native-lib.cpp glue

# The new engine changed two APIs the plugin's JNI glue calls. The old
# native-lib.cpp (native_llama 1.0.1, April 2026) does not compile against
# the new headers, so the script rewrites those two call sites:
#
# 1. llama_sampler_init_penalties gained a leading n_vocab argument:
#    (n_vocab, penalty_last_n, penalty_repeat, penalty_freq, penalty_present).
#    The old call passed (128, 1.2f, 0.1f, 0.1f); the new call keeps those
#    four values and prepends the vocab size, which the function already has
#    as `vocab` (llama_vocab_n_tokens).
# 2. mtmd_helper_bitmap_init_from_file now takes (ctx, fname, placeholder,
#    opt) and returns a mtmd_helper_bitmap_wrapper instead of a raw
#    mtmd_bitmap *. placeholder=false decodes the image, as the old call
#    did; the bitmap is taken out of the wrapper so the rest of the function
#    (which pushes it into a vector<mtmd_bitmap *>) is unchanged.
NATIVE_LIB_PENALTIES_OLD = (
    "llama_sampler_init_penalties(128, 1.2f, 0.1f, 0.1f)"
)
NATIVE_LIB_PENALTIES_NEW = (
    "llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 128, 1.2f, 0.1f, 0.1f)"
)

NATIVE_LIB_BITMAP_OLD = (
    "mtmd_bitmap * bmp = mtmd_helper_bitmap_init_from_file(mtmd_ctx, m_path);"
)
NATIVE_LIB_BITMAP_NEW = (
    "struct mtmd_helper_bitmap_wrapper wrap = mtmd_helper_bitmap_init_from_file(\n"
    "mtmd_ctx, m_path, false, mtmd_helper_init_opt_default());\n"
    "mtmd_bitmap * bmp = wrap.bitmap;"
)


def patch_native_lib(package_root: Path) -> int:
    """Rewrite the two native-lib.cpp call sites for the new engine's APIs.

    Only applies when the vendored tree is the new engine (checked by the
    MINICPM5 marker, the same marker update_engine uses). On the stock April
    2026 tree the old calls are correct, so the patch is skipped there.
    Returns the number of replacements made. Raises SystemExit if a call
    site is in an unrecognised state, so CI fails loudly.
    """
    vocab_h = package_root / "ios" / "shared_cpp" / "src" / "llama-vocab.h"
    if not vocab_h.is_file() or "MINICPM5" not in vocab_h.read_text():
        print("old engine; native-lib.cpp calls are correct as-is, skipping")
        return 0

    native_lib = (
        package_root / "android" / "src" / "main" / "cpp" / "native-lib.cpp"
    )
    if not native_lib.is_file():
        raise SystemExit(
            "::error::native-lib.cpp not found under %s" % package_root
        )

    text = native_lib.read_text()
    changed = 0

    if NATIVE_LIB_PENALTIES_NEW in text:
        print("native-lib.cpp penalties call already updated; skipping")
    elif NATIVE_LIB_PENALTIES_OLD in text:
        text = text.replace(
            NATIVE_LIB_PENALTIES_OLD, NATIVE_LIB_PENALTIES_NEW, 1
        )
        changed += 1
        print("patched native-lib.cpp (penalties call, n_vocab first arg)")
    else:
        raise SystemExit(
            "::error::unrecognised penalties call in %s" % native_lib
        )

    if NATIVE_LIB_BITMAP_NEW in text:
        print("native-lib.cpp bitmap call already updated; skipping")
    elif NATIVE_LIB_BITMAP_OLD in text:
        text = text.replace(NATIVE_LIB_BITMAP_OLD, NATIVE_LIB_BITMAP_NEW, 1)
        changed += 1
        print("patched native-lib.cpp (bitmap call, wrapper + defaults)")
    else:
        raise SystemExit(
            "::error::unrecognised bitmap call in %s" % native_lib
        )

    if changed:
        native_lib.write_text(text)
    return changed


def main() -> int:
    args = set(sys.argv[1:])
    require_gpu = "--require-gpu" in args
    # Clawzilla default: CPU-only builds. The Vulkan backend's registration
    # crashes model load on the S23 FE, so GPU offload is opt-in (--gpu)
    # instead of auto-detect. --cpu is accepted but redundant.
    force_cpu = "--cpu" in args or ("--gpu" not in args and not require_gpu)

    glslc = None if force_cpu else glslc_path()
    enable_gpu = glslc is not None

    if require_gpu and not enable_gpu:
        print(
            "::error::--require-gpu was passed but glslc is not installed. "
            "Install it (apt-get install -y glslc) before building."
        )
        return 1

    print("glslc: %s" % (glslc or "not found"))
    print("mode : %s" % ("GPU (Vulkan enabled)" if enable_gpu else "CPU only"))

    roots: list[Path] = []
    if os.environ.get("PUB_CACHE"):
        roots.append(Path(os.environ["PUB_CACHE"]))
    roots.append(Path.home() / ".pub-cache")
    roots.append(Path.cwd() / ".dart_tool")

    seen: set[Path] = set()
    bases: list[Path] = []
    for root in roots:
        if root in seen or not root.is_dir():
            continue
        seen.add(root)
        bases.extend(sorted(root.glob("**/native_llama-*/android")))

    if not bases:
        print("::error::native_llama not found; searched:")
        for root in seen:
            print("  - %s" % root)
        return 1

    patched = 0
    for base in bases:
        cmake = base / "src/main/cpp/CMakeLists.txt"
        gradle = base / "build.gradle.kts"

        if cmake.is_file() and patch_cmake(cmake, enable_gpu):
            patched += 1
            print(
                "patched %s (GGML_VULKAN=%s)"
                % (cmake, "ON" if enable_gpu else "OFF")
            )

        if gradle.is_file() and patch_gradle(gradle, enable_gpu):
            patched += 1
            print(
                "patched %s (%s %s)"
                % (
                    gradle,
                    "kept" if enable_gpu else "dropped",
                    GRADLE_FLAG,
                )
            )

        # Engine update (independent of the Vulkan mode): swap the vendored
        # April 2026 llama.cpp for a pinned current snapshot, so a new GGUF
        # loads without a per-model patch. On the new tree the MiniCPM5
        # vocab patch below is a no-op (the tree already knows it).
        if update_engine(base.parent):
            patched += 1

        # JNI glue for the new engine's changed APIs (penalties + mtmd
        # bitmap). Skipped on the old tree, where the old calls are correct.
        patched += patch_native_lib(base.parent)

        # MiniCPM5 tokenizer support (independent of the Vulkan mode).
        # No-op on the updated engine, which already knows "minicpm5"; kept
        # so the script still fixes the stock April 2026 tree if the engine
        # update is ever skipped.
        patched += patch_vocab(base.parent)

    if patched == 0:
        print("native_llama already in the requested state; nothing to do")
    else:
        print("patched %d file(s)" % patched)

    if enable_gpu:
        print(
            "Vulkan enabled: the APK accepts n_gpu_layers > 0 and will fall "
            "back to the CPU on devices without a working Vulkan driver."
        )
    else:
        print("Vulkan disabled: inference runs on the CPU backend.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
