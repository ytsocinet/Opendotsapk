/// Catalog of cloud LLM providers supported through bring-your-own-key.
///
/// Design constraints that shaped this list:
///
///  * **The user supplies the key.** There is no backend, no proxy, no shared
///    quota. We never see or bill anyone's usage.
///  * **OpenAI-compatible first.** Most providers speak the
///    `/chat/completions` shape, so one client covers many of them. Native
///    providers (Anthropic, Gemini) get their own wire format.
///  * **Local stays the default.** Nothing here is contacted unless the user
///    adds a key *and* the router selects cloud for a given turn.
///
/// Model IDs are refreshed Nov 12, 2026 — the old lists had gone stale and
/// the APIs were failing: `gemini-2.0-flash` shut down June 1, 2026,
/// `gemini-2.5-pro` was deprecated Nov 2, 2026 (routed to `gemini-3.8-flash`
/// from Dec 1), and Groq shut both Llama models down for free/developer
/// keys on Aug 16, 2026. A saved model that is no longer in its provider's
/// list falls back to that provider's default (see `_refreshRouter` in
/// the Cloud screen), so a stale pick fails over instead of 404ing.
/// Prices marked 0 were not pinned when the list was written; the UI hides
/// them rather than showing a made-up number.
library;

enum CloudWireFormat {
  /// `POST {baseUrl}/chat/completions` with `Authorization: Bearer`.
  openAiCompatible,

  /// Anthropic Messages API: `/v1/messages`, `x-api-key`, `anthropic-version`.
  anthropic,

  /// Google Gemini: `:generateContent`, key as a query parameter.
  gemini,
}

class CloudModel {
  final String id;
  final String displayName;
  final int contextTokens;

  /// Indicative USD per 1M tokens, for the cost estimator only. These drift;
  /// they are labelled "approx" in the UI and never used for billing.
  final double inputPricePerM;
  final double outputPricePerM;

  /// Whether the model can accept image input.
  final bool supportsVision;

  const CloudModel({
    required this.id,
    required this.displayName,
    this.contextTokens = 128000,
    this.inputPricePerM = 0,
    this.outputPricePerM = 0,
    this.supportsVision = false,
  });
}

class CloudProvider {
  final String id;
  final String displayName;
  final CloudWireFormat wireFormat;
  final String defaultBaseUrl;

  /// Where the user gets a key. Shown as a link in the settings screen.
  final String keyUrl;

  /// Whether the API key is passed as a query parameter rather than a header.
  final List<CloudModel> models;

  /// Substrings to look for in the key, to catch obvious paste mistakes.
  final String keyHint;

  const CloudProvider({
    required this.id,
    required this.displayName,
    required this.wireFormat,
    required this.defaultBaseUrl,
    required this.keyUrl,
    required this.models,
    this.keyHint = '',
  });

  CloudModel? modelById(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// First model, used as the default when a provider is first configured.
  CloudModel get defaultModel => models.first;
}

class CloudCatalog {
  CloudCatalog._();

  static const List<CloudProvider> providers = [
    CloudProvider(
      id: 'openai',
      displayName: 'OpenAI',
      wireFormat: CloudWireFormat.openAiCompatible,
      defaultBaseUrl: 'https://api.openai.com/v1',
      keyUrl: 'https://platform.openai.com/api-keys',
      keyHint: 'sk-',
      models: [
        CloudModel(
          id: 'gpt-5.6-sol',
          displayName: 'GPT-5.6 Sol',
          contextTokens: 128000,
          // Promotional pricing until Nov 30, 2026; check before trusting it.
          inputPricePerM: 4.00,
          outputPricePerM: 20.00,
          supportsVision: true,
        ),
        CloudModel(
          id: 'gpt-5.6-terra',
          displayName: 'GPT-5.6 Terra',
          contextTokens: 128000,
          supportsVision: true,
        ),
        CloudModel(
          id: 'gpt-4o-mini',
          displayName: 'GPT-4o mini',
          contextTokens: 128000,
          inputPricePerM: 0.15,
          outputPricePerM: 0.60,
          supportsVision: true,
        ),
        CloudModel(
          id: 'gpt-4o',
          displayName: 'GPT-4o',
          contextTokens: 128000,
          inputPricePerM: 2.50,
          outputPricePerM: 10.00,
          supportsVision: true,
        ),
      ],
    ),
    CloudProvider(
      id: 'anthropic',
      displayName: 'Anthropic',
      wireFormat: CloudWireFormat.anthropic,
      defaultBaseUrl: 'https://api.anthropic.com/v1',
      keyUrl: 'https://console.anthropic.com/settings/keys',
      keyHint: 'sk-ant-',
      models: [
        // Sonnet 4.5 retires Nov 30, 2026; Sonnet 5-5 is Anthropic's named
        // replacement.
        CloudModel(
          id: 'claude-sonnet-5-5',
          displayName: 'Claude Sonnet 5-5',
          contextTokens: 200000,
          supportsVision: true,
        ),
        CloudModel(
          id: 'claude-3-5-haiku-latest',
          displayName: 'Claude 3.5 Haiku',
          contextTokens: 200000,
          inputPricePerM: 0.80,
          outputPricePerM: 4.00,
          supportsVision: true,
        ),
      ],
    ),
    CloudProvider(
      id: 'gemini',
      displayName: 'Google Gemini',
      wireFormat: CloudWireFormat.gemini,
      defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      keyUrl: 'https://aistudio.google.com/app/apikey',
      models: [
        // Google's own advice for new projects (Nov 2026): 3.8 Flash for
        // everyday work, 3.5 Flash-Lite for the cheap seat. The free AI
        // Studio tier is $0, so no prices are shown.
        CloudModel(
          id: 'gemini-3.8-flash',
          displayName: 'Gemini 3.8 Flash',
          contextTokens: 1000000,
          supportsVision: true,
        ),
        CloudModel(
          id: 'gemini-3.5-flash-lite',
          displayName: 'Gemini 3.5 Flash-Lite',
          contextTokens: 1000000,
          supportsVision: true,
        ),
      ],
    ),
    CloudProvider(
      id: 'groq',
      displayName: 'Groq (fast inference)',
      wireFormat: CloudWireFormat.openAiCompatible,
      defaultBaseUrl: 'https://api.groq.com/openai/v1',
      keyUrl: 'https://console.groq.com/keys',
      keyHint: 'gsk_',
      models: [
        // Groq's own replacements for the Llama models it shut down for
        // free/developer keys on Aug 16, 2026.
        CloudModel(
          id: 'openai/gpt-oss-120b',
          displayName: 'GPT-OSS 120B',
          contextTokens: 131072,
          inputPricePerM: 0.15,
          outputPricePerM: 0.60,
        ),
        CloudModel(
          id: 'openai/gpt-oss-20b',
          displayName: 'GPT-OSS 20B',
          contextTokens: 131072,
          inputPricePerM: 0.075,
          outputPricePerM: 0.30,
        ),
      ],
    ),
    CloudProvider(
      id: 'deepseek',
      displayName: 'DeepSeek',
      wireFormat: CloudWireFormat.openAiCompatible,
      defaultBaseUrl: 'https://api.deepseek.com/v1',
      keyUrl: 'https://platform.deepseek.com/api_keys',
      keyHint: 'sk-',
      models: [
        CloudModel(
          id: 'deepseek-chat',
          displayName: 'DeepSeek V3',
          contextTokens: 64000,
          inputPricePerM: 0.27,
          outputPricePerM: 1.10,
        ),
      ],
    ),
    CloudProvider(
      id: 'openrouter',
      displayName: 'OpenRouter (many models, one key)',
      wireFormat: CloudWireFormat.openAiCompatible,
      defaultBaseUrl: 'https://openrouter.ai/api/v1',
      keyUrl: 'https://openrouter.ai/keys',
      keyHint: 'sk-or-',
      models: [
        CloudModel(
          id: 'anthropic/claude-3.5-sonnet',
          displayName: 'Claude 3.5 Sonnet (via OR)',
          contextTokens: 200000,
          inputPricePerM: 3.00,
          outputPricePerM: 15.00,
          supportsVision: true,
        ),
        CloudModel(
          id: 'meta-llama/llama-3.3-70b-instruct',
          displayName: 'Llama 3.3 70B (via OR)',
          contextTokens: 128000,
          inputPricePerM: 0.12,
          outputPricePerM: 0.30,
        ),
      ],
    ),
    CloudProvider(
      id: 'ollama',
      displayName: 'Ollama / LM Studio (self-hosted, LAN)',
      wireFormat: CloudWireFormat.openAiCompatible,
      defaultBaseUrl: 'http://192.168.1.10:11434/v1',
      keyUrl: 'https://ollama.com/download',
      models: [
        CloudModel(
          id: 'llama3.2',
          displayName: 'llama3.2 (your server)',
          contextTokens: 128000,
        ),
      ],
    ),
    CloudProvider(
      id: 'custom',
      displayName: 'Custom OpenAI-compatible endpoint',
      wireFormat: CloudWireFormat.openAiCompatible,
      defaultBaseUrl: 'https://example.com/v1',
      keyUrl: '',
      models: [
        CloudModel(
          id: 'default',
          displayName: 'Any model id',
          contextTokens: 32000,
        ),
      ],
    ),
  ];

  static CloudProvider? byId(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Providers that do not require an API key (a LAN server may be open).
  static const Set<String> keyOptional = {'ollama', 'custom'};
}
