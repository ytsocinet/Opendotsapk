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
"""

from __future__ import annotations

import os
import shutil
import sys
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

        # MiniCPM5 tokenizer support (independent of the Vulkan mode).
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
