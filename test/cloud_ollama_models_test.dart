/// Build #103: the Ollama provider lists the server's live models.
///
/// Covers the two units the feature rests on:
///  * `CloudProvider.acceptsStoredModel` — the router's gate: an unlisted
///    id is now accepted for Ollama (like OpenRouter), so a model picked
///    from the server's live list survives `_refreshRouter` instead of
///    falling back to the pinned llama3.2. Every other provider still
///    only accepts its pinned ids.
///  * `CloudService.parseOpenAiModelList` — the /v1/models payload parser
///    shared by the OpenRouter and Ollama live lists, tested against a
///    realistic Ollama-shaped payload (ids only, no names, no context
///    lengths) without a network call. The router's keep-vs-fallback
///    decision itself lives in the screen's private `_refreshRouter` and
///    is covered here through the gate it consults.
library;

import 'package:clawzilla/data/services/cloud_service.dart';
import 'package:clawzilla/domain/models/cloud_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudProvider.acceptsStoredModel', () {
    final ollama = CloudCatalog.byId('ollama')!;
    final gemini = CloudCatalog.byId('gemini')!;
    final openRouter = CloudCatalog.byId('openrouter')!;

    test('ollama accepts an unlisted model id from its server', () {
      expect(ollama.acceptsStoredModel('my-server-model:3b'), isTrue);
    });

    test('ollama still accepts its pinned llama3.2', () {
      expect(ollama.acceptsStoredModel('llama3.2'), isTrue);
    });

    test('ollama rejects an empty model id', () {
      expect(ollama.acceptsStoredModel(''), isFalse);
    });

    test('other providers still reject unlisted ids', () {
      expect(gemini.acceptsStoredModel('my-server-model:3b'), isFalse);
      expect(gemini.acceptsStoredModel('gemini-3.8-flash'), isTrue);
    });

    test('openrouter still accepts any non-empty id', () {
      expect(openRouter.acceptsStoredModel('some/future-model'), isTrue);
    });
  });

  group('CloudService.parseOpenAiModelList', () {
    test('parses an Ollama-shaped /v1/models payload', () {
      // What Ollama actually returns: ids only, no names, no context
      // lengths. The parser must not require the OpenRouter extras.
      final models = CloudService.parseOpenAiModelList({
        'object': 'list',
        'data': [
          {
            'id': 'my-server-model:3b',
            'object': 'model',
            'created': 1759000000,
            'owned_by': 'library',
          },
          {
            'id': 'llama3.2',
            'object': 'model',
            'created': 1759000001,
            'owned_by': 'library',
          },
        ],
      }, 'Ollama');

      expect(models.map((m) => m.id).toList(), [
        'llama3.2',
        'my-server-model:3b',
      ]);
      // Display name falls back to the id; context defaults to 128k.
      expect(models.first.displayName, 'llama3.2');
      expect(models.first.contextTokens, 128000);
      expect(models.last.displayName, 'my-server-model:3b');
    });

    test('keeps a provided name and context length', () {
      final models = CloudService.parseOpenAiModelList({
        'data': [
          {
            'id': 'anthropic/claude-sonnet-5.5',
            'name': 'Claude Sonnet 5.5',
            'context_length': 200000,
          },
        ],
      }, 'OpenRouter');

      expect(models.single.displayName, 'Claude Sonnet 5.5');
      expect(models.single.contextTokens, 200000);
    });

    test('skips entries with a missing or empty id', () {
      final models = CloudService.parseOpenAiModelList({
        'data': [
          {'id': ''},
          {'name': 'no id at all'},
          'not a map',
          {'id': 'kept'},
        ],
      }, 'Ollama');

      expect(models.map((m) => m.id).toList(), ['kept']);
    });

    test('throws on a malformed payload', () {
      expect(
        () => CloudService.parseOpenAiModelList({'nope': true}, 'Ollama'),
        throwsA(
          isA<CloudException>().having(
            (e) => e.message,
            'message',
            'Ollama sent an unexpected model list.',
          ),
        ),
      );
      expect(
        () => CloudService.parseOpenAiModelList(null, 'Ollama'),
        throwsA(isA<CloudException>()),
      );
    });

    test('an empty data list parses to an empty list', () {
      expect(
        CloudService.parseOpenAiModelList({'data': []}, 'Ollama'),
        isEmpty,
      );
    });
  });
}
