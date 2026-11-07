package com.localmind.localmind

import android.service.voice.VoiceInteractionService

/**
 * Top-level digital-assistant service. The class body is empty on
 * purpose: its existence in the manifest is what makes Clawzilla show
 * up in the Digital assistant picker (Settings → Advanced features →
 * Side button → Long press → Digital assistant). The system binds to
 * it; the session service does the work.
 */
class CypherVoiceInteractionService : VoiceInteractionService()
