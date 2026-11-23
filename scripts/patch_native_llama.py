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

## Native trace

Build #99: safe mode works but the full local prompt kills every turn with
a 90-second TimeoutException and no token — and the app has no native-side
error channel, so the timeout is the only symptom. This script also
instruments the plugin's JNI glue (`android/src/main/cpp/native-lib.cpp`,
which the engine swap above does NOT touch — it replaces only
`ios/shared_cpp`) with a generation trace: one line per stage of
`startNativeGeneration` — entered, chat template applied, tokenized N
tokens, each prefill chunk with its `llama_decode` return code, first token
sent, EOS, tokens sent — appended to `native_trace.log` in the app docs
dir, where the Diagnostics screen shows it. The trace path is set from
Kotlin at engine attach (`NativeLlamaPlugin.kt`, same package), so the
native code never guesses a path. All logging failures are swallowed and
the file is truncated past ~200 KB, so tracing can never break generation
or fill storage. The replacements follow the same pattern as the glue
patches above: exact strings, idempotent, loud failure on unrecognised
state.
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

    print("engine updated to llama.cpp %s" % LLAMA_CPP_COMMIT)
    return True


def reconcile_cmake(package_root: Path) -> int:
    """Reconcile the plugin's CMakeLists with the vendored tree on disk.

    Runs on EVERY invocation, whether the engine was just replaced or was
    already current. This matters because the CI caches the pub-cache: a
    tree updated by an earlier run can persist while the plugin's CMakeLists
    still lacks the new tree's files, so gating this on the download would
    silently skip the fix on the next run.

    Two reconciliations, both driven by what the tree on disk actually has:
    1. Drop the clip.cpp line when the tree lacks tools/mtmd/clip.cpp (the
       new tree dropped it; CMake fails on a missing source file).
    2. Add the new tree's split mtmd sources (mtmd-graph.cpp,
       mtmd-model.cpp, mtmd-subcontext.cpp, mtmd-helper-gen.cpp) right after
       the mtmd.cpp line, when the tree has them and the list lacks them.
       Without them the link fails with undefined mtmd_graph / mtmd_model /
       mtmd_subcontext symbols.
    Returns the number of changes made.
    """
    shared_cpp = package_root / "ios" / "shared_cpp"
    cmake = (
        package_root / "android" / "src" / "main" / "cpp" / "CMakeLists.txt"
    )
    if not cmake.is_file():
        return 0

    changed = 0
    text = cmake.read_text()

    if not (shared_cpp / "tools" / "mtmd" / "clip.cpp").is_file():
        lines = text.splitlines(keepends=True)
        kept = [ln for ln in lines if "tools/mtmd/clip.cpp" not in ln]
        if len(kept) != len(lines):
            text = "".join(kept)
            changed += 1
            print("dropped clip.cpp from %s (absent in vendored tree)" % cmake)

    mtmd_new = (
        "mtmd-graph.cpp",
        "mtmd-model.cpp",
        "mtmd-subcontext.cpp",
        "mtmd-helper-gen.cpp",
    )
    anchor = '"${SHARED_CPP_DIR}/tools/mtmd/mtmd.cpp"\n'
    missing = [
        f
        for f in mtmd_new
        if (shared_cpp / "tools" / "mtmd" / f).is_file() and f not in text
    ]
    if missing and anchor in text:
        insert = "".join(
            '    "${SHARED_CPP_DIR}/tools/mtmd/%s"\n' % f for f in missing
        )
        text = text.replace(anchor, anchor + insert, 1)
        changed += 1
        print(
            "added %s to %s (new mtmd sources)"
            % (", ".join(missing), cmake)
        )

    # The new tree's mtmd-helper.cpp calls hash_sha256_hex, implemented in
    # the vendored vendor/hash library (vendor::hash target, built by the
    # tree's root CMakeLists). The plugin links only `llama`, so the symbol
    # is undefined at link time. Link vendor::hash too, when the tree has
    # it. The old tree has no vendor/hash and its mtmd-helper never calls
    # it, so this is a no-op there.
    if (
        (shared_cpp / "vendor" / "hash" / "hash.cpp").is_file()
        and "vendor::hash" not in text
    ):
        link_old = (
            "target_link_libraries(native_llama llama dl vulkan ${log-lib})"
        )
        link_new = (
            "target_link_libraries(native_llama llama vendor::hash "
            "dl vulkan ${log-lib})"
        )
        if link_old in text:
            text = text.replace(link_old, link_new, 1)
            changed += 1
            print("linked vendor::hash in %s (new mtmd needs it)" % cmake)

    if changed:
        cmake.write_text(text)
    return changed


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


# ------------------------------------------------------- native trace (build #99)
#
# The replacements below instrument the JNI glue with a generation trace.
# They use raw triple-quoted strings so the `\n` inside C++ string
# literals stays literal. Each pair is (old, new, label); `_replace_once`
# checks for `new` first, so a second run finds the patch already present
# and skips instead of doubling the code.

TRACE_CPP_REPLACEMENTS = [
    (
        [
            # Build #126 migrates the #99 form (listed first) to the
            # pristine anchor. <chrono> is already in the stock file, so
            # only <ctime> is added — localtime_r/strftime for the
            # per-line timestamp.
            r'''#include <thread>
#include <cstdarg>
#include <cstdio>
#include "llama.h"''',
            r'''#include <thread>
#include "llama.h"''',
        ],
        r'''#include <thread>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include "llama.h"''',
        "trace includes",
    ),
    (
        [
            # Build #126 migrates the #99 form (listed first): the pristine
            # anchor is a prefix substring of it, so it must be tried
            # after the previous `new` text, or the helper would be
            # duplicated instead of replaced.
            r'''static bool stop_generation = false;

// --- Clawzilla native trace (build #99) ---
// One line per generation stage, appended to native_trace.log in the app's
// docs dir (path set from Kotlin at engine attach). A silent native failure
// — no token, no error, no crash — is otherwise invisible to Dart, so the
// 90-second timeout is the only symptom. Every failure here is swallowed
// and the file is truncated past ~200 KB: tracing must never break
// generation or fill storage.
static std::string trace_path;
static int trace_tokens_sent = 0;

static void trace_log(const char* fmt, ...) {
    if (trace_path.empty()) return;
    FILE* f = fopen(trace_path.c_str(), "a");
    if (f == nullptr) return;
    struct stat st;
    if (stat(trace_path.c_str(), &st) == 0 && st.st_size > 200 * 1024) {
        fclose(f);
        f = fopen(trace_path.c_str(), "w");
        if (f == nullptr) return;
    }
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    fprintf(f, "%s\n", buf);
    fclose(f);
}''',
            r'''static bool stop_generation = false;''',
        ],
        r'''static bool stop_generation = false;

// --- Clawzilla native trace (build #99) ---
// One line per generation stage, appended to native_trace.log in the app's
// docs dir (path set from Kotlin at engine attach). A silent native failure
// — no token, no error, no crash — is otherwise invisible to Dart, so the
// 90-second timeout is the only symptom. Every failure here is swallowed
// and the file is truncated past ~200 KB: tracing must never break
// generation or fill storage.
//
// Build #126: every line carries a wall-clock timestamp ([HH:MM:SS.mmm]).
// The trace had no durations, so "prefill was slow" and "the turn never
// reached native" looked identical. The timestamp also lets a trace line
// be correlated with the Dart log's own timestamps in the Activity screen.
static std::string trace_path;
static int trace_tokens_sent = 0;

static void trace_log(const char* fmt, ...) {
    if (trace_path.empty()) return;
    FILE* f = fopen(trace_path.c_str(), "a");
    if (f == nullptr) return;
    struct stat st;
    if (stat(trace_path.c_str(), &st) == 0 && st.st_size > 200 * 1024) {
        fclose(f);
        f = fopen(trace_path.c_str(), "w");
        if (f == nullptr) return;
    }
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    const auto now = std::chrono::system_clock::now();
    const std::time_t t = std::chrono::system_clock::to_time_t(now);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char tbuf[16];
    strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tmv);
    const long long ms =
        (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch())
            .count() %
        1000;
    fprintf(f, "[%s.%03lld] %s\n", tbuf, ms, buf);
    fclose(f);
}''',
        "trace helper",
    ),
    (
        r'''JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_abortGeneration(JNIEnv *env, jobject thiz) {''',
        r'''JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_setTracePath(JNIEnv *env, jobject thiz, jstring trace_path_j) {
    if (trace_path_j == nullptr) return;
    const char* p = env->GetStringUTFChars(trace_path_j, nullptr);
    if (p != nullptr) {
        trace_path = std::string(p);
        env->ReleaseStringUTFChars(trace_path_j, p);
    }
}

JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_abortGeneration(JNIEnv *env, jobject thiz) {''',
        "setTracePath JNI",
    ),
    (
        r'''        jstring js = env->NewStringUTF(s.c_str());
        env->CallVoidMethod(thiz, methodID, js);
        env->DeleteLocalRef(js);
        return true;''',
        r'''        jstring js = env->NewStringUTF(s.c_str());
        env->CallVoidMethod(thiz, methodID, js);
        env->DeleteLocalRef(js);
        if (trace_tokens_sent == 0) trace_log("first token sent");
        trace_tokens_sent++;
        return true;''',
        "token counter",
    ),
    (
        # Build #127: this anchor deliberately excludes the JNI signature
        # line. The signature gains (generation_id, max_tokens) in the
        # guards below, and anchoring on it would make this replacement
        # unrecognisable on re-runs against a #127-patched tree (the CI
        # pub cache persists), failing the build loudly for no reason.
        # The null-check line itself is unique in the file (the only
        # other null-context return is `return nullptr;` in getEmbedding).
        r'''if (ctx == nullptr || model == nullptr) return;''',
        r'''if (ctx == nullptr || model == nullptr) { trace_log("generate: no model/context loaded"); return; }
trace_tokens_sent = 0;''',
        "generation entry",
    ),
    (
        r'''bool use_draft = (ctx_draft != nullptr && n_media == 0);''',
        r'''bool use_draft = (ctx_draft != nullptr && n_media == 0);
trace_log("generate: entered n_msg=%d n_media=%d draft=%d temp=%.2f top_k=%d top_p=%.2f n_ctx=%u", env->GetArrayLength(roles), n_media, use_draft ? 1 : 0, temperature, top_k, top_p, llama_n_ctx(ctx));''',
        "generation entered",
    ),
    (
        r'''std::string prompt_str = formatted_prompt.data();''',
        r'''std::string prompt_str = formatted_prompt.data();
trace_log("template: formatted %d chars (%s)", n_formatted, tmpl_ptr != nullptr ? "model template" : "fallback");''',
        "template applied",
    ),
    (
        r'''n_prompt_tokens_total = prompt_tokens.size();''',
        r'''n_prompt_tokens_total = prompt_tokens.size();
trace_log("tokenize: %d prompt tokens", n_prompt_tokens_total);''',
        "prompt tokenized",
    ),
    (
        r'''if (llama_decode(ctx, batch) != 0) {
llama_batch_free(batch);
llama_sampler_free(smpl);
return;
}''',
        r'''int decode_rc = llama_decode(ctx, batch);
trace_log("prefill: chunk at %d/%d tokens rc=%d", n_eval, (int)prompt_tokens.size(), decode_rc);
if (decode_rc != 0) {
llama_batch_free(batch);
llama_sampler_free(smpl);
trace_log("prefill: FAILED rc=%d, returning with no token and no error", decode_rc);
return;
}''',
        "prefill decode",
    ),
    (
        r'''LOGE("MTMD Tokenize failed with error code: %d", tok_res);''',
        r'''LOGE("MTMD Tokenize failed with error code: %d", tok_res);
trace_log("mtmd: tokenize FAILED rc=%d", tok_res);''',
        "mtmd tokenize failure",
    ),
    (
        r'''LOGI("Media evaluation complete! Context cursor is now at: %d", n_cur);''',
        r'''LOGI("Media evaluation complete! Context cursor is now at: %d", n_cur);
trace_log("mtmd: evaluated, cursor at %d", n_cur);''',
        "mtmd evaluated",
    ),
    (
        r'''jstring eos = env->NewStringUTF("__END_OF_STREAM__");
env->CallVoidMethod(thiz, methodID, eos);
env->DeleteLocalRef(eos);''',
        r'''jstring eos = env->NewStringUTF("__END_OF_STREAM__");
env->CallVoidMethod(thiz, methodID, eos);
env->DeleteLocalRef(eos);
trace_log("eos: stream closed, tokens_sent=%d", trace_tokens_sent);''',
        "end of stream",
    ),
]

TRACE_KOTLIN_REPLACEMENTS = [
    (
        r'''    private external fun abortGeneration()''',
        r'''    private external fun abortGeneration()
    private external fun setTracePath(path: String)''',
        "setTracePath declaration",
    ),
    (
        [
            # Build #127 migrates the #126 form (listed first): the
            # pristine anchor is a prefix substring of it, so it must be
            # tried after the previous `new` text, or the setTracePath
            # block would be duplicated instead of replaced.
            r'''        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_llama/events")
        eventChannel.setStreamHandler(this)

        // Clawzilla build #99: tell the native glue where to write the
        // generation trace (native_trace.log in the app docs dir), so a
        // silent native failure is visible in the Diagnostics screen.
        // path_provider's docs dir on Android is <filesDir>/app_flutter.
        // Build #126: create the directory first. fopen() in the native
        // glue fails silently when the parent dir does not exist, which
        // makes every trace_log call a no-op and the trace permanently
        // empty — exactly the symptom seen on the phone (empty trace
        // after a working turn). mkdirs() is a no-op when it exists.
        val traceFile = java.io.File(
            flutterPluginBinding.applicationContext.filesDir,
            "app_flutter/native_trace.log",
        )
        traceFile.parentFile?.mkdirs()
        setTracePath(traceFile.absolutePath)
    }''',
            r'''        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_llama/events")
        eventChannel.setStreamHandler(this)
    }''',
        ],
        r'''        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_llama/events")
        eventChannel.setStreamHandler(this)

        // Clawzilla build #99: tell the native glue where to write the
        // generation trace (native_trace.log in the app docs dir), so a
        // silent native failure is visible in the Diagnostics screen.
        // Build #127: the path MUST be the directory path_provider
        // returns for getApplicationDocumentsDirectory() — that is
        // Context.getDir("flutter", MODE_PRIVATE), i.e.
        // <dataDir>/app_flutter, NOT <filesDir>/app_flutter. Builds
        // #99-#126 used filesDir, so the glue wrote the trace to
        // files/app_flutter/native_trace.log while Dart and the
        // Diagnostics screen read app_flutter/native_trace.log — the
        // trace was being written all along, to a file nobody reads
        // (proven on the phone: #126's health line printed the Dart
        // path with no /files/ segment, and the trace stayed empty
        // after a working turn). getDir creates the directory, so no
        // mkdirs() is needed.
        val traceFile = java.io.File(
            flutterPluginBinding.applicationContext.getDir(
                "flutter",
                android.content.Context.MODE_PRIVATE,
            ),
            "native_trace.log",
        )
        setTracePath(traceFile.absolutePath)
    }''',
        "trace path at attach",
    ),
]


def _replace_once(text, old, new, label, path):
    """Apply one exact-string replacement, idempotently.

    Returns (text, changed). If the replacement is already present, skips
    (the script runs on every build; the pub cache may already be patched).
    If neither old nor new is found, fails loudly so CI never ships a
    silently uninstrumented build.

    `old` may be a list of candidate anchors, tried in order. That is how
    a replacement whose `new` text changed across builds migrates an
    already-patched tree: the previous build's `new` text is listed first,
    and the pristine anchor last. The order matters whenever the pristine
    anchor is a substring of the previous `new` — replacing on it would
    duplicate the instrumented code instead of replacing it. The CI pub
    cache persists between runs (flutter-action `cache: true`), so the run
    after a `new` change meets the previous build's text, not the pristine
    one; without the list form that run would fail loudly (or worse,
    double-patch).
    """
    if new in text:
        print("%s already present in %s; skipping" % (label, path))
        return text, 0
    candidates = old if isinstance(old, (list, tuple)) else [old]
    for candidate in candidates:
        if candidate in text:
            return text.replace(candidate, new, 1), 1
    raise SystemExit(
        "::error::unrecognised %s in %s" % (label, path)
    )


def patch_native_trace(package_root: Path) -> int:
    """Instrument the JNI glue with a generation trace (build #99).

    Adds a `trace_log` helper plus a `setTracePath` JNI entry to
    native-lib.cpp, log calls at each stage of `startNativeGeneration`,
    and the Kotlin call that sets the trace path at engine attach. The
    glue file is NOT touched by the engine swap (only `ios/shared_cpp`
    is replaced), so these anchors hold on both the old and the new tree
    and no engine gate is needed — but they must not overlap the two
    call sites `patch_native_lib` rewrites (penalties, mtmd bitmap),
    and they do not. Returns the number of replacements made. Raises
    SystemExit if a site is in an unrecognised state, so CI fails loudly.
    """
    native_lib = (
        package_root / "android" / "src" / "main" / "cpp" / "native-lib.cpp"
    )
    if not native_lib.is_file():
        raise SystemExit(
            "::error::native-lib.cpp not found under %s" % package_root
        )
    kotlin = (
        package_root
        / "android"
        / "src"
        / "main"
        / "kotlin"
        / "com"
        / "timebox"
        / "native_llama"
        / "NativeLlamaPlugin.kt"
    )
    if not kotlin.is_file():
        raise SystemExit(
            "::error::NativeLlamaPlugin.kt not found under %s" % package_root
        )

    text = native_lib.read_text()
    changed = 0
    for old, new, label in TRACE_CPP_REPLACEMENTS:
        text, n = _replace_once(text, old, new, label, native_lib)
        changed += n
    if changed:
        native_lib.write_text(text)
        print(
            "patched native-lib.cpp (native trace, %d site(s))" % changed
        )

    ktext = kotlin.read_text()
    kchanged = 0
    for old, new, label in TRACE_KOTLIN_REPLACEMENTS:
        ktext, n = _replace_once(ktext, old, new, label, kotlin)
        kchanged += n
    if kchanged:
        kotlin.write_text(ktext)
        print(
            "patched NativeLlamaPlugin.kt (trace path, %d site(s))"
            % kchanged
        )
    return changed + kchanged


# Build #127 (local hang, Piece B — stop the bleeding) + trace-path root
# cause. Three small native-side guards, independently testable, that
# convert "every turn hangs forever" into "at most one slow turn":
#  (1) the prefill loop checks the stop flag once per chunk, so a turn
#      that timed out mid-prefill ends after the current chunk instead of
#      running to completion while the next turn queues behind it;
#  (2) generation ids — Kotlin mints one per startGeneration request and
#      publishes it to native immediately; a generation whose id is no
#      longer the latest aborts at entry instead of clearing an abort
#      meant for a newer turn and generating into the void;
#  (3) a native max-token bound — a listener-less generation ends after
#      max_tokens instead of running until EOG or context fill.
# The ids are minted in Kotlin (it is the side that enqueues onto the
# executor), so the plugin's Dart file only gains the maxTokens
# pass-through. All anchors below are the post-trace-patch forms:
# patch_native_trace runs first in main(), so a pristine tree is already
# in its #99/#126 form by the time this runs — an anchor in any other
# state fails loudly, which is the contract.
GUARD_CPP_REPLACEMENTS = [
    (
        # Build #127: <atomic> goes AFTER "llama.h", not between <ctime>
        # and it — the trace-includes replacement above must still match
        # as a substring on re-runs of this script on an already-patched
        # tree (the CI pub cache persists), and inserting a line inside
        # its block would break that match and fail the build loudly.
        # Build #128: the latest_generation_id declaration lives here,
        # right after the <atomic> include — NOT next to
        # stop_generation, where it was first tried. Two reasons. (1)
        # C++ needs the declaration before its first use, and
        # startNativeGeneration (which uses it) is defined BEFORE
        # setTracePath, so a declaration before setTracePath sat ~330
        # lines below the use and run #141 failed with "use of
        # undeclared identifier" (native-lib.cpp:333-334). (2) The
        # declaration cannot sit between `static bool stop_generation`
        # and the trace helper: the trace helper's `new` text starts
        # with that line, and any line inserted after it breaks the
        # helper's idempotency check, so a re-run would duplicate the
        # whole trace helper. The includes block is the only stable
        # anchor: this `new` ends with the declaration, so what follows
        # it cannot break the match.
        [
            r'''#include <thread>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include "llama.h"
#include <atomic>''',
            r'''#include <thread>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include "llama.h"''',
        ],
        r'''#include <thread>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include "llama.h"
#include <atomic>
// The latest generation id requested from Kotlin (see
// setLatestGenerationId). Declared here, before every use: C++ needs a
// file-scope declaration before its first use in startNativeGeneration.
static std::atomic<int> latest_generation_id{0};''',
        "guard includes",
    ),
    (
        # Build #127: the guard code goes BEFORE the setTracePath block,
        # not after it — the trace replacement's new text is the
        # setTracePath block immediately followed by the abortGeneration
        # line, and appending between them would break that match on
        # re-runs (the CI pub cache persists) and duplicate the
        # setTracePath function. Prepending keeps it intact.
        # Build #128: the declaration line is GONE from this block — it
        # now lives right after the <atomic> include at the top of the
        # file (see the "guard includes" replacement). The first
        # candidate is #127's form, so a #127-patched tree migrates
        # (old declaration removed); the pristine anchor is last.
        [
            r'''// --- Clawzilla generation guards (build #127) ---
// The latest generation id requested from Kotlin (see
// setLatestGenerationId). A generation whose id is no longer the latest
// was superseded while queued behind a slow prefill and aborts at entry
// instead of running into the void.
static std::atomic<int> latest_generation_id{0};

JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_setLatestGenerationId(JNIEnv *env, jobject thiz, jint generation_id) {
    latest_generation_id.store((int)generation_id);
}

JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_setTracePath(JNIEnv *env, jobject thiz, jstring trace_path_j) {
    if (trace_path_j == nullptr) return;
    const char* p = env->GetStringUTFChars(trace_path_j, nullptr);
    if (p != nullptr) {
        trace_path = std::string(p);
        env->ReleaseStringUTFChars(trace_path_j, p);
    }
}''',
            r'''JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_setTracePath(JNIEnv *env, jobject thiz, jstring trace_path_j) {
    if (trace_path_j == nullptr) return;
    const char* p = env->GetStringUTFChars(trace_path_j, nullptr);
    if (p != nullptr) {
        trace_path = std::string(p);
        env->ReleaseStringUTFChars(trace_path_j, p);
    }
}''',
        ],
        r'''// --- Clawzilla generation guards (build #127) ---
// The latest generation id requested from Kotlin (see
// setLatestGenerationId). A generation whose id is no longer the latest
// was superseded while queued behind a slow prefill and aborts at entry
// instead of running into the void. The latest_generation_id variable
// itself is declared right after the <atomic> include at the top of
// the file (build #128): it must precede its first use in
// startNativeGeneration.
JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_setLatestGenerationId(JNIEnv *env, jobject thiz, jint generation_id) {
    latest_generation_id.store((int)generation_id);
}

JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_setTracePath(JNIEnv *env, jobject thiz, jstring trace_path_j) {
    if (trace_path_j == nullptr) return;
    const char* p = env->GetStringUTFChars(trace_path_j, nullptr);
    if (p != nullptr) {
        trace_path = std::string(p);
        env->ReleaseStringUTFChars(trace_path_j, p);
    }
}''',
        "latest generation id",
    ),
    (
        r'''Java_com_timebox_native_1llama_NativeLlamaPlugin_startNativeGeneration(JNIEnv *env, jobject thiz, jobjectArray roles, jobjectArray contents, jobjectArray media_paths, jfloat temperature, jint top_k, jfloat top_p) {
if (ctx == nullptr || model == nullptr) { trace_log("generate: no model/context loaded"); return; }
trace_tokens_sent = 0;''',
        r'''Java_com_timebox_native_1llama_NativeLlamaPlugin_startNativeGeneration(JNIEnv *env, jobject thiz, jobjectArray roles, jobjectArray contents, jobjectArray media_paths, jfloat temperature, jint top_k, jfloat top_p, jint generation_id, jint max_tokens) {
if (ctx == nullptr || model == nullptr) { trace_log("generate: no model/context loaded"); return; }
trace_tokens_sent = 0;
// Build #127 (H3): a generation superseded while queued behind a slow
// prefill aborts here, before it can clear an abort meant for a newer
// turn or generate into the void. The check must come before the
// stop_generation reset below: a stale generation must never touch the
// flag. generation_id <= 0 means "no id supplied" — treat as current.
if (generation_id > 0 && generation_id != latest_generation_id.load()) {
trace_log("generate: stale id %d (latest %d), aborting at entry", (int)generation_id, latest_generation_id.load());
return;
}
if (max_tokens <= 0) max_tokens = 512;''',
        "generation entry guards",
    ),
    (
        r'''int decode_rc = llama_decode(ctx, batch);
trace_log("prefill: chunk at %d/%d tokens rc=%d", n_eval, (int)prompt_tokens.size(), decode_rc);
if (decode_rc != 0) {
llama_batch_free(batch);
llama_sampler_free(smpl);
trace_log("prefill: FAILED rc=%d, returning with no token and no error", decode_rc);
return;
}''',
        r'''int decode_rc = llama_decode(ctx, batch);
trace_log("prefill: chunk at %d/%d tokens rc=%d", n_eval, (int)prompt_tokens.size(), decode_rc);
if (decode_rc != 0) {
llama_batch_free(batch);
llama_sampler_free(smpl);
trace_log("prefill: FAILED rc=%d, returning with no token and no error", decode_rc);
return;
}
// Build #127 (H3): check the stop flag once per prefill chunk. Before
// this, a turn that timed out mid-prefill kept decoding until prefill
// finished — minutes — holding the single-thread executor while the
// next turn queued behind it. Now it ends after the current chunk.
if (stop_generation) {
llama_batch_free(batch);
llama_sampler_free(smpl);
trace_log("prefill: aborted by stop flag at %d/%d tokens", n_eval, (int)prompt_tokens.size());
return;
}''',
        "prefill stop check",
    ),
    (
        r'''while (true) {
if (stop_generation || is_eog_reached) break;''',
        r'''while (true) {
if (stop_generation || is_eog_reached) break;
// Build #127 (H3): bound the native loop. A generation nobody is
// listening to — Dart timed out, the stream is gone — used to run until
// EOG or context fill; now it ends once max_tokens have been sent (the
// EOS below still closes the stream cleanly). trace_tokens_sent counts
// tokens sent this generation (reset at entry, incremented in sendToken
// whether or not the trace path is set), so the bound holds even with
// tracing unset. A draft round can send a few tokens past the bound in
// one iteration; that overshoot is harmless — the bound is a safety
// net, and Dart still enforces its own exact cap.
if (trace_tokens_sent >= max_tokens) {
trace_log("generate: max_tokens %d reached, ending generation", (int)max_tokens);
break;
}''',
        "decode max tokens",
    ),
    (
        # Build #130 (Piece D): prefill in 1024-token chunks instead of
        # the stock 512 — fewer, bigger llama_decode calls for the prompt.
        # The on-phone trace is the measurement: its chunk lines read
        # 0/1393, 1024/1393, ... and their timestamps show whether
        # prefill got faster. 1024 sits safely inside n_ctx 4096, and
        # the draft/vision path (n_batch 256) is untouched. The anchor
        # is unique in the stock file; on re-runs the `new` text is
        # already present so _replace_once skips.
        r'''cparams.n_batch = 512;''',
        r'''// Build #130 (Piece D): 1024-token prefill chunks — fewer, bigger
// decodes than the stock 512. Measured on-phone via trace chunk lines.
cparams.n_batch = 1024;''',
        "prefill batch 1024",
    ),
]

GUARD_KOTLIN_REPLACEMENTS = [
    (
        r'''    private external fun abortGeneration()
    private external fun setTracePath(path: String)''',
        r'''    private external fun abortGeneration()
    private external fun setTracePath(path: String)
    private external fun setLatestGenerationId(id: Int)''',
        "setLatestGenerationId declaration",
    ),
    (
        r'''    private external fun startNativeGeneration(roles: Array<String>, contents: Array<String>, mediaPaths: Array<String>, temperature: Float, topK: Int, topP: Float)''',
        r'''    private external fun startNativeGeneration(roles: Array<String>, contents: Array<String>, mediaPaths: Array<String>, temperature: Float, topK: Int, topP: Float, generationId: Int, maxTokens: Int)''',
        "startNativeGeneration signature",
    ),
    (
        r'''    private val executor = Executors.newSingleThreadExecutor()''',
        r'''    private val executor = Executors.newSingleThreadExecutor()

    // Build #127: monotonically increasing generation id (see
    // "startGeneration" below). Minted on the method-call thread only.
    private var latestGenerationId = 0''',
        "latest generation id field",
    ),
    (
        r'''            "startGeneration" -> {
                val roles = call.argument<List<String>>("roles")?.toTypedArray()
                val contents = call.argument<List<String>>("contents")?.toTypedArray()

                // --- MODIFIED: Extract mediaPaths (defaults to empty array if none) ---
                val mediaPaths = call.argument<List<String>>("mediaPaths")?.toTypedArray() ?: emptyArray()

                // Cast Double from Dart to Float for Kotlin/C++ boundary
                val temperature = call.argument<Double>("temperature")?.toFloat() ?: 0.7f
                val topK = call.argument<Int>("topK") ?: 40
                val topP = call.argument<Double>("topP")?.toFloat() ?: 0.9f

                if (roles != null && contents != null) {
                    executor.execute {
                        startNativeGeneration(roles, contents, mediaPaths, temperature, topK, topP)
                    }
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "Roles or contents are null", null)
                }
            }''',
        r'''            "startGeneration" -> {
                val roles = call.argument<List<String>>("roles")?.toTypedArray()
                val contents = call.argument<List<String>>("contents")?.toTypedArray()

                // --- MODIFIED: Extract mediaPaths (defaults to empty array if none) ---
                val mediaPaths = call.argument<List<String>>("mediaPaths")?.toTypedArray() ?: emptyArray()

                // Cast Double from Dart to Float for Kotlin/C++ boundary
                val temperature = call.argument<Double>("temperature")?.toFloat() ?: 0.7f
                val topK = call.argument<Int>("topK") ?: 40
                val topP = call.argument<Double>("topP")?.toFloat() ?: 0.9f
                val maxTokens = call.argument<Int>("maxTokens") ?: 512

                if (roles != null && contents != null) {
                    // Build #127: tag this generation and publish the id
                    // to native NOW, on the method-call thread — not when
                    // the queued call eventually runs. A turn that timed
                    // out may still be queued behind a slow prefill when
                    // the next turn arrives; native aborts a generation
                    // whose id is no longer the latest at entry, instead
                    // of clearing an abort meant for a newer turn and
                    // generating into the void.
                    latestGenerationId += 1
                    val generationId = latestGenerationId
                    setLatestGenerationId(generationId)
                    executor.execute {
                        startNativeGeneration(roles, contents, mediaPaths, temperature, topK, topP, generationId, maxTokens)
                    }
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "Roles or contents are null", null)
                }
            }''',
        "startGeneration handler",
    ),
]

GUARD_DART_REPLACEMENTS = [
    (
        r'''  /// Generates response and streams tokens back to the UI
  Stream<String> generateResponse(
      List<Map<String, String>> messages, {
        List<String>? mediaPaths, // --- MODIFIED: Accepts images & audio files ---
        double temperature = 0.7,
        int topK = 40,
        double topP = 0.9,
      }) {''',
        r'''  /// Generates response and streams tokens back to the UI.
  ///
  /// [maxTokens] bounds the native loop (build #127): a generation with
  /// no listener ends after this many tokens instead of running until
  /// EOG or context fill.
  Stream<String> generateResponse(
      List<Map<String, String>> messages, {
        List<String>? mediaPaths, // --- MODIFIED: Accepts images & audio files ---
        double temperature = 0.7,
        int topK = 40,
        double topP = 0.9,
        int maxTokens = 512,
      }) {''',
        "generateResponse maxTokens param",
    ),
    (
        r'''        'temperature': temperature,
        'topK': topK,
        'topP': topP,
      })''',
        r'''        'temperature': temperature,
        'topK': topK,
        'topP': topP,
        'maxTokens': maxTokens,
      })''',
        "startGeneration maxTokens arg",
    ),
]


def patch_generation_guards(package_root: Path) -> int:
    """Apply the build #127 generation guards (Piece B of the local hang
    fix).

    Patches the JNI glue (native-lib.cpp), the Kotlin plugin and the
    plugin's Dart file with: a stop-flag check in the prefill loop,
    generation ids (stale generations abort at entry), and a native
    max-token bound. Must run after patch_native_trace in main() — the
    C++ anchors are the post-trace-patch forms. Returns the number of
    replacements made. Raises SystemExit if a site is in an unrecognised
    state, so CI fails loudly.
    """
    native_lib = (
        package_root / "android" / "src" / "main" / "cpp" / "native-lib.cpp"
    )
    if not native_lib.is_file():
        raise SystemExit(
            "::error::native-lib.cpp not found under %s" % package_root
        )
    kotlin = (
        package_root
        / "android"
        / "src"
        / "main"
        / "kotlin"
        / "com"
        / "timebox"
        / "native_llama"
        / "NativeLlamaPlugin.kt"
    )
    if not kotlin.is_file():
        raise SystemExit(
            "::error::NativeLlamaPlugin.kt not found under %s" % package_root
        )
    dart = package_root / "lib" / "native_llama.dart"
    if not dart.is_file():
        raise SystemExit(
            "::error::native_llama.dart not found under %s" % package_root
        )

    text = native_lib.read_text()
    changed = 0
    for old, new, label in GUARD_CPP_REPLACEMENTS:
        text, n = _replace_once(text, old, new, label, native_lib)
        changed += n
    if changed:
        native_lib.write_text(text)
        print(
            "patched native-lib.cpp (generation guards, %d site(s))"
            % changed
        )

    ktext = kotlin.read_text()
    kchanged = 0
    for old, new, label in GUARD_KOTLIN_REPLACEMENTS:
        ktext, n = _replace_once(ktext, old, new, label, kotlin)
        kchanged += n
    if kchanged:
        kotlin.write_text(ktext)
        print(
            "patched NativeLlamaPlugin.kt (generation guards, %d site(s))"
            % kchanged
        )

    dtext = dart.read_text()
    dchanged = 0
    for old, new, label in GUARD_DART_REPLACEMENTS:
        dtext, n = _replace_once(dtext, old, new, label, dart)
        dchanged += n
    if dchanged:
        dart.write_text(dtext)
        print(
            "patched native_llama.dart (generation guards, %d site(s))"
            % dchanged
        )
    return changed + kchanged + dchanged


# ------------------------------------------------------- keep model loaded (build #132)
#
# Nov 23, 2026: the 12:21 turn worked, every later turn logged
# "generate: no model/context loaded" and waited out the 300s prefill
# timeout. Root cause, proven from the plugin source: native_llama's
# NativeLlamaPlugin.onDetachedFromEngine calls disposeLlama(), and the
# model/context are process-wide statics in the .so. Any FlutterEngine
# that attaches this plugin and later detaches frees the main session's
# model. The foreground service (background mode starts one on any turn
# over 2s; wake mode toggles one) creates a background engine whose Dart
# callback calls DartPluginRegistrant.ensureInitialized() — so the plugin
# IS attached there — and stopping the service destroys that engine.
# The first turn after any service stop therefore generates against
# nothing, while both Dart-side flags (_isLoaded, _isInitialized) still
# say loaded. Two changes, in the same patch run as the trace and the
# guards:
#  (1) onDetachedFromEngine stops disposing: the explicit "dispose"
#      method call (LlmService.release) remains the only dispose path.
#      A model left loaded on main-engine detach is harmless — the
#      process is going away, and a later initLlama frees the old
#      model first.
#  (2) a native isModelLoaded probe (C++ JNI + Kotlin + plugin Dart),
#      so LlmService can ask the native side directly before each turn
#      instead of trusting Dart flags that cannot see a native unload.
# Must run after patch_generation_guards in main() — the Kotlin
# declaration anchor is the post-guard form.

MODEL_LOADED_CPP_REPLACEMENTS = [
    (
        # The anchor is disposeLlama, NOT abortGeneration: the trace
        # patch's "setTracePath JNI" replacement ends with the
        # abortGeneration signature, so anything inserted between
        # setTracePath and abortGeneration breaks that replacement's
        # idempotency check — its `new` text is no longer contiguous,
        # its `old` still matches, and every re-run duplicates both
        # functions (proven in scratch: a probe anchored on
        # abortGeneration duplicated setTracePath + isModelLoaded on
        # the second run, and duplicate JNI definitions do not
        # compile). Nothing else inserts before disposeLlama, so this
        # anchor stays contiguous across runs.
        r'''JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_disposeLlama(JNIEnv *env, jobject thiz) {''',
        r'''// Clawzilla build #132: isModelLoaded probe. The Dart-side flags
// (LlmService._isLoaded, NativeLlama._isInitialized) cannot see a
// native-side unload, so generateStream asks the native side directly
// before each turn. Pure pointer check — no inference, no state change.
JNIEXPORT jboolean JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_isModelLoaded(JNIEnv *env, jobject thiz) {
    return (model != nullptr && ctx != nullptr) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_timebox_native_1llama_NativeLlamaPlugin_disposeLlama(JNIEnv *env, jobject thiz) {''',
        "isModelLoaded JNI",
    ),
]

MODEL_LOADED_KOTLIN_REPLACEMENTS = [
    (
        # Post-guard form: the trace patch added setTracePath after
        # abortGeneration, the guards added setLatestGenerationId after
        # that. This patch runs after both in main(), so the anchor is
        # the post-guard form on a pristine tree too.
        r'''    private external fun abortGeneration()
    private external fun setTracePath(path: String)
    private external fun setLatestGenerationId(id: Int)''',
        r'''    private external fun abortGeneration()
    private external fun setTracePath(path: String)
    private external fun setLatestGenerationId(id: Int)
    private external fun isModelLoaded(): Boolean''',
        "isModelLoaded declaration",
    ),
    (
        r'''            "abortGeneration" -> {
                abortGeneration()
                result.success(true)
            }''',
        r'''            "abortGeneration" -> {
                abortGeneration()
                result.success(true)
            }
            "isModelLoaded" -> {
                // Build #132: ask the native side whether a model and
                // context are actually loaded. Runs on the executor like
                // getCpuCores: the read itself is a pointer check, but
                // the writes it races (init/dispose) run there.
                executor.execute {
                    val loaded = isModelLoaded()
                    handler.post { result.success(loaded) }
                }
            }''',
        "isModelLoaded handler",
    ),
    (
        r'''    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        disposeLlama()
    }''',
        r'''    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        // Build #132: do NOT disposeLlama() here. The native model and
        // context are process-wide statics in the .so, but every engine
        // that attaches this plugin detaches it on destroy — including
        // the foreground service's background engine (its Dart callback
        // registers all plugins) and WorkManager's. Disposing here freed
        // the main session's model from under a live chat: the first
        // turn after any foreground-service stop hit "generate: no
        // model/context loaded" and waited out the 300s prefill timeout
        // (Nov 23). The explicit "dispose" method call
        // (LlmService.release) remains the only dispose path. A model
        // left loaded on main-engine detach is harmless: the process is
        // going away, and a later initLlama frees the old model first.
    }''',
        "detach keeps model loaded",
    ),
]

MODEL_LOADED_DART_REPLACEMENTS = [
    (
        r'''  /// Force stops the current generation loop
  Future<void> abortGeneration() async {
    await _methodChannel.invokeMethod('abortGeneration');
  }''',
        r'''  /// Force stops the current generation loop
  Future<void> abortGeneration() async {
    await _methodChannel.invokeMethod('abortGeneration');
  }

  /// True when the native side still holds a loaded model and context.
  ///
  /// Build #132: the Dart-side [_isInitialized] flag cannot see a
  /// native-side unload (a background engine's detach used to dispose
  /// the model from under a live session), so LlmService asks native
  /// directly before each turn instead of trusting the flag. A failed
  /// probe reads as not loaded — the caller reloads, which is safe
  /// even if the probe itself was the problem.
  Future<bool> isModelLoaded() async {
    try {
      return await _methodChannel.invokeMethod('isModelLoaded') ?? false;
    } catch (_) {
      return false;
    }
  }''',
        "isModelLoaded Dart method",
    ),
]


def patch_model_loaded(package_root: Path) -> int:
    """Apply the build #132 keep-model-loaded fix.

    Patches the JNI glue (native-lib.cpp) with an isModelLoaded probe,
    the Kotlin plugin with the probe declaration + handler and with a
    detach that no longer disposes the model, and the plugin's Dart
    file with the probe method. Must run after patch_generation_guards
    in main() — the Kotlin declaration anchor is the post-guard form.
    Returns the number of replacements made. Raises SystemExit if a
    site is in an unrecognised state, so CI fails loudly.
    """
    native_lib = (
        package_root / "android" / "src" / "main" / "cpp" / "native-lib.cpp"
    )
    if not native_lib.is_file():
        raise SystemExit(
            "::error::native-lib.cpp not found under %s" % package_root
        )
    kotlin = (
        package_root
        / "android"
        / "src"
        / "main"
        / "kotlin"
        / "com"
        / "timebox"
        / "native_llama"
        / "NativeLlamaPlugin.kt"
    )
    if not kotlin.is_file():
        raise SystemExit(
            "::error::NativeLlamaPlugin.kt not found under %s" % package_root
        )
    dart = package_root / "lib" / "native_llama.dart"
    if not dart.is_file():
        raise SystemExit(
            "::error::native_llama.dart not found under %s" % package_root
        )

    text = native_lib.read_text()
    changed = 0
    for old, new, label in MODEL_LOADED_CPP_REPLACEMENTS:
        text, n = _replace_once(text, old, new, label, native_lib)
        changed += n
    if changed:
        native_lib.write_text(text)
        print(
            "patched native-lib.cpp (model-loaded probe, %d site(s))"
            % changed
        )

    ktext = kotlin.read_text()
    kchanged = 0
    for old, new, label in MODEL_LOADED_KOTLIN_REPLACEMENTS:
        ktext, n = _replace_once(ktext, old, new, label, kotlin)
        kchanged += n
    if kchanged:
        kotlin.write_text(ktext)
        print(
            "patched NativeLlamaPlugin.kt (model-loaded probe + detach, "
            "%d site(s))" % kchanged
        )

    dtext = dart.read_text()
    dchanged = 0
    for old, new, label in MODEL_LOADED_DART_REPLACEMENTS:
        dtext, n = _replace_once(dtext, old, new, label, dart)
        dchanged += n
    if dchanged:
        dart.write_text(dtext)
        print(
            "patched native_llama.dart (model-loaded probe, %d site(s))"
            % dchanged
        )
    return changed + kchanged + dchanged


def drop_stale_onnxruntime_so(roots: list[Path]) -> int:
    """Delete the onnxruntime package's bundled libonnxruntime.so files.

    The `onnxruntime` Dart package (v1.4.1, last updated 2024) ships a
    prebuilt ONNX Runtime 1.15.1 .so in android/src/main/jniLibs/. The
    wake-word detector (wake_word_flutter -> flutter_onnxruntime) ships
    ONNX Runtime 1.28.0 via Maven. Both provide lib/arm64-v8a/
    libonnxruntime.so, and Gradle's pickFirst takes the onnxruntime
    package's 1.15.1 copy — verified in the build #57 APK (strings show
    1.15.1). flutter_onnxruntime expects 1.28.0 APIs, so the detector
    segfaults on start and the app closes to the home screen.

    Removing the stale .so files here (after `flutter pub get`, before
    the Gradle build) leaves flutter_onnxruntime's 1.28.0 .so as the only
    copy in the APK. The embeddings service (embedding_service.dart,
    which uses the onnxruntime package's Dart FFI) then loads 1.28.0 at
    runtime; ONNX Runtime's C API is backward compatible, so the old
    calls resolve against the newer library.

    Idempotent (a missing file is already dropped) and never fatal: if
    the package is not found, warn and continue so the build is not
    blocked. Returns the number of files deleted.
    """
    deleted = 0
    seen: set[Path] = set()
    for root in roots:
        if not root.is_dir():
            continue
        for so in sorted(
            root.glob("**/onnxruntime-*/android/src/main/jniLibs/*/libonnxruntime.so")
        ):
            if so in seen:
                continue
            seen.add(so)
            try:
                so.unlink()
                deleted += 1
                print("dropped stale onnxruntime .so: %s" % so)
            except OSError as exc:
                print("warning: could not drop %s: %s" % (so, exc))
    if deleted == 0:
        print("no stale onnxruntime .so found (already dropped or absent)")
    return deleted


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

        # CMakeLists reconciliation (runs EVERY time, even when the engine
        # was already current — the CI caches the pub-cache, so a tree
        # updated by an earlier run can persist while the plugin's
        # CMakeLists still lacks the new tree's files).
        patched += reconcile_cmake(base.parent)

        # JNI glue for the new engine's changed APIs (penalties + mtmd
        # bitmap). Skipped on the old tree, where the old calls are correct.
        patched += patch_native_lib(base.parent)

        # Native generation trace (build #99): instruments the JNI glue
        # with per-stage logging to native_trace.log, so a silent native
        # failure is visible in the Diagnostics screen. Applies to both
        # trees — the glue is untouched by the engine swap.
        patched += patch_native_trace(base.parent)

        # Generation guards (build #127, Piece B of the local hang fix):
        # stop-flag check in the prefill loop, generation ids, and a
        # native max-token bound. Runs after the trace patch — its C++
        # anchors are the post-trace-patch forms.
        patched += patch_generation_guards(base.parent)

        # Keep the model loaded (build #132): the detach no longer
        # disposes the model, and a native isModelLoaded probe lets
        # LlmService verify the model before each turn. Runs after the
        # guards — its Kotlin declaration anchor is the post-guard form.
        patched += patch_model_loaded(base.parent)

        # MiniCPM5 tokenizer support (independent of the Vulkan mode).
        # No-op on the updated engine, which already knows "minicpm5"; kept
        # so the script still fixes the stock April 2026 tree if the engine
        # update is ever skipped.
        patched += patch_vocab(base.parent)

    # Drop the onnxruntime package's stale 1.15.1 .so files so the APK
    # ships only flutter_onnxruntime's 1.28.0 copy (wake-word detector
    # crashes on 1.15.1). Runs every build; safe when already dropped.
    drop_stale_onnxruntime_so(roots)

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
