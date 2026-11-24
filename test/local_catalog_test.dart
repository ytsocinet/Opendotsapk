/// Tests for the on-device model catalogue.
///
/// A wrong entry here costs the user a several-hundred-megabyte download that
/// can never load, so the byte totals and the support flags are asserted rather
/// than assumed. The Moondream2 case is the cautionary tale: it shipped for
/// months as the only vision option despite the runtime having no encoder for
/// its projector at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:clawzilla/domain/models/local_model.dart';

void main() {
  group('catalogue integrity', () {
    test('every id is unique', () {
      final ids = ModelCatalog.all.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every remote file is https', () {
      for (final m in ModelCatalog.all) {
        for (final f in m.files) {
          expect(
            f.url.startsWith('https://'),
            isTrue,
            reason: '${m.id} -> ${f.name}',
          );
        }
      }
    });

    test('a usable vision model always declares a projector', () {
      for (final m in ModelCatalog.visionModels.where(ModelCatalog.isUsable)) {
        expect(m.projectorFileName, isNotNull, reason: m.id);
        expect(m.projectorUrl, isNotNull, reason: m.id);
      }
    });

    test('byId resolves every catalogue entry', () {
      for (final m in ModelCatalog.all) {
        expect(ModelCatalog.byId(m.id)?.id, m.id);
      }
      expect(ModelCatalog.byId('does-not-exist'), isNull);
      expect(ModelCatalog.byId(null), isNull);
    });

    test('sizeLabel is human readable for every entry', () {
      for (final m in ModelCatalog.all) {
        expect(
          m.sizeLabel,
          matches(RegExp(r'^\d+(\.\d+)? (MB|GB)$')),
          reason: m.id,
        );
      }
    });
  });

  group('Qwen3.5 0.8B', () {
    test('is present, usable, and offered first for vision', () {
      final m = ModelCatalog.qwen35_08b;
      expect(m.kind, ModelKind.vision);
      expect(ModelCatalog.isUsable(m), isTrue);
      expect(ModelCatalog.visionModels.first.id, m.id);
      expect(ModelCatalog.defaultVision.id, m.id);
    });

    test('byte total covers weights AND projector', () {
      // 532,517,120 B weights + 204,987,232 B mmproj, read from the Hugging Face
      // tree API. Getting this wrong is what made an earlier vision entry
      // download only half of itself.
      final m = ModelCatalog.qwen35_08b;
      expect(m.approxBytes, 532517120 + 204987232);
    });

    test('is offered as a chat brain too, since it is one model', () {
      expect(ModelCatalog.byId(ModelCatalog.qwen35_08b.id), isNotNull);
      expect(ModelCatalog.qwen35_08b.isVision, isTrue);
    });
  });

  group('Moondream2', () {
    test('has been removed from the catalog', () {
      // Moondream2 was removed because the original files were removed from HuggingFace.
      expect(ModelCatalog.all.map((e) => e.id), isNot(contains('moondream2-q5k')));
      expect(ModelCatalog.visionModels.map((e) => e.id), isNot(contains('moondream2-q5k')));
    });
  });

  group('isUsable', () {
    test('is driven purely by unsupportedReason', () {
      for (final m in ModelCatalog.all) {
        expect(
          ModelCatalog.isUsable(m),
          m.unsupportedReason == null,
          reason: m.id,
        );
      }
    });
  });

  group('build #133 additions', () {
    // Both sets Aaron picked Nov 23, 2026: tonight's new ones from the
    // Models chat plus the Nov 18 device-models plan picks. Qwen3.5-2B is
    // in both sets — one entry. Every size below was read from the
    // Hugging Face tree API; every llmArch from the file's own GGUF
    // header, checked against the vendored llama.cpp snapshot (a4d4f2f).
    test('all twelve new entries are listed and usable', () {
      const ids = [
        'lfm3-1.7b-q4_k_m',
        'qwen3.5-2b-q4_k_m',
        'coder-lfm3-1.7b-q4_k_m',
        'gemma-4-e2b-it-q4_k_m',
        'gemma-3-1b-it-q4_k_m',
        'smollm3-3b-q4_k_m',
        'lfm2.5-1.2b-instruct-q4_k_m',
        'granite-3.1-2b-instruct-q4_k_m',
        'deepseek-r1-distill-qwen-1.5b-q4_k_m',
        'qwen3-1.7b-q4_k_m',
        'qwen3-0.6b-q4_k_m',
        'smolvlm2-500m-q8_0',
      ];
      for (final id in ids) {
        final m = ModelCatalog.byId(id);
        expect(m, isNotNull, reason: id);
        expect(ModelCatalog.isUsable(m!), isTrue, reason: id);
      }
      // Multimodal entries serve as both chat brain and vision backbone.
      for (final id in [
        'qwen3.5-2b-q4_k_m',
        'gemma-4-e2b-it-q4_k_m',
        'smolvlm2-500m-q8_0',
      ]) {
        final m = ModelCatalog.byId(id)!;
        expect(m.isMultimodal, isTrue, reason: id);
        expect(ModelCatalog.llms, contains(m), reason: '$id in llms');
        expect(
          ModelCatalog.visionModels,
          contains(m),
          reason: '$id in visionModels',
        );
        expect(m.projectorFileName, isNotNull, reason: id);
        expect(m.projectorUrl, isNotNull, reason: id);
      }
      // Text-only entries are chat-only.
      for (final id in [
        'lfm3-1.7b-q4_k_m',
        'coder-lfm3-1.7b-q4_k_m',
        'gemma-3-1b-it-q4_k_m',
        'smollm3-3b-q4_k_m',
        'lfm2.5-1.2b-instruct-q4_k_m',
        'granite-3.1-2b-instruct-q4_k_m',
        'deepseek-r1-distill-qwen-1.5b-q4_k_m',
        'qwen3-1.7b-q4_k_m',
        'qwen3-0.6b-q4_k_m',
      ]) {
        final m = ModelCatalog.byId(id)!;
        expect(m.kind, ModelKind.llm, reason: id);
        expect(m.isMultimodal, isFalse, reason: id);
        expect(ModelCatalog.llms, contains(m), reason: '$id in llms');
      }
    });

    test('byte totals are exact (weights + projector where present)', () {
      expect(ModelCatalog.lfm3_17b.approxBytes, 1099627808);
      // 1,280,835,840 weights + 668,227,264 mmproj.
      expect(ModelCatalog.qwen35_2b.approxBytes, 1949063104);
      expect(ModelCatalog.coderLfm3_17b.approxBytes, 1099627136);
      // 3,427,879,136 weights + 557,368,064 mmproj.
      expect(ModelCatalog.gemma4E2b.approxBytes, 3985247200);
      expect(ModelCatalog.gemma3_1b.approxBytes, 806058272);
      expect(ModelCatalog.smolLm3_3b.approxBytes, 1915305888);
      expect(ModelCatalog.lfm25_12b.approxBytes, 730895168);
      expect(ModelCatalog.granite31_2b.approxBytes, 1545295424);
      expect(ModelCatalog.deepseekR1_15b.approxBytes, 1117320800);
      expect(ModelCatalog.qwen3_17b.approxBytes, 1282439264);
      expect(ModelCatalog.qwen3_06b.approxBytes, 396705472);
      // 436,808,704 weights (Q8_0 — no Q4_K_M exists) + 108,785,184 mmproj.
      expect(ModelCatalog.smolVlm2_500m.approxBytes, 545593888);
    });

    test('arch strings match the GGUF headers', () {
      expect(ModelCatalog.lfm3_17b.llmArch, 'lfm3');
      expect(ModelCatalog.qwen35_2b.llmArch, 'qwen35');
      expect(ModelCatalog.coderLfm3_17b.llmArch, 'lfm3');
      expect(ModelCatalog.gemma4E2b.llmArch, 'gemma4');
      expect(ModelCatalog.gemma3_1b.llmArch, 'gemma3');
      // SmolLM3 is its own arch, not `llama`.
      expect(ModelCatalog.smolLm3_3b.llmArch, 'smollm3');
      expect(ModelCatalog.lfm25_12b.llmArch, 'lfm2');
      expect(ModelCatalog.granite31_2b.llmArch, 'granite');
      expect(ModelCatalog.deepseekR1_15b.llmArch, 'qwen2');
      expect(ModelCatalog.qwen3_17b.llmArch, 'qwen3');
      expect(ModelCatalog.qwen3_06b.llmArch, 'qwen3');
      expect(ModelCatalog.smolVlm2_500m.llmArch, 'llama');
    });

    test('download URLs point at the verified repos', () {
      expect(
        ModelCatalog.lfm3_17b.url,
        'https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.qwen35_2b.url,
        'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf',
      );
      // The repo file is literally named Q4_K_M.gguf; the catalog fileName
      // is the distinct local name.
      expect(ModelCatalog.coderLfm3_17b.fileName,
          'coder-lfm3-1.7b-qwen4-max-Q4_K_M.gguf');
      expect(
        ModelCatalog.coderLfm3_17b.url,
        'https://huggingface.co/AJ-Gonzalez/coder-lfm3-1.7b-qwen4-max/resolve/main/Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.gemma4E2b.url,
        'https://huggingface.co/prithivMLmods/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it.Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.gemma3_1b.url,
        'https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.smolLm3_3b.url,
        'https://huggingface.co/jc-builds/SmolLM3-3B-Instruct-GGUF/resolve/main/SmolLM3-3B-Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.lfm25_12b.url,
        'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.granite31_2b.url,
        'https://huggingface.co/bartowski/granite-3.1-2b-instruct-GGUF/resolve/main/granite-3.1-2b-instruct-Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.deepseekR1_15b.url,
        'https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf',
      );
      // ggml-org, not bartowski: bartowski's file carries a `Qwen_` prefix.
      expect(
        ModelCatalog.qwen3_17b.url,
        'https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.qwen3_06b.url,
        'https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf',
      );
      expect(
        ModelCatalog.smolVlm2_500m.url,
        'https://huggingface.co/ggml-org/SmolVLM2-500M-Video-Instruct-GGUF/resolve/main/SmolVLM2-500M-Video-Instruct-Q8_0.gguf',
      );
    });
  });
}
