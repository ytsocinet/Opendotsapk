package com.localmind.localmind

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

/**
 * The assistant gesture (side-button long press, home long-press,
 * corner swipe) lands here. The session opens the app on the
 * clawzilla://talk deep link — MainActivity notes the launch and the
 * chat screen starts listening — then finishes immediately. No
 * overlay, no separate voice UI: the chat screen IS the assistant UI.
 */
class CypherVoiceInteractionSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession =
        CypherVoiceInteractionSession(this)
}

class CypherVoiceInteractionSession(
    context: Context,
) : VoiceInteractionSession(context) {
    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("clawzilla://talk")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        context.startActivity(intent)
        finish()
    }
}
