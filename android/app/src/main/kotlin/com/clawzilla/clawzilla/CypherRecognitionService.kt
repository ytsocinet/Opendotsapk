package com.clawzilla.clawzilla

import android.content.Intent
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * Stub recognition service. The framework requires one to be declared
 * in voice_interaction_service.xml for the assistant component to be
 * valid (VoiceInteractionServiceInfo rejects the service with a parse
 * error otherwise), but Clawzilla does its speech recognition through
 * the platform speech services in the chat screen, not through this.
 * Every callback here refuses the request.
 */
class CypherRecognitionService : RecognitionService() {
    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        listener?.error(SpeechRecognizer.ERROR_CLIENT)
    }

    override fun onCancel(listener: Callback?) {
        listener?.error(SpeechRecognizer.ERROR_CLIENT)
    }

    override fun onStopListening(listener: Callback?) {
        listener?.error(SpeechRecognizer.ERROR_CLIENT)
    }
}
