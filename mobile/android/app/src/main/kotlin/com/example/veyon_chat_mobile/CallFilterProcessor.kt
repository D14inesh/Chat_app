package com.example.veyon_chat_mobile

import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import java.nio.ByteBuffer

/**
 * Colour filters for the OUTGOING camera in a video call — the website's
 * call filters (Mono, Warm, Cool, Vivid, Vintage, Noir, Soft). Applied to
 * every frame before it's encoded, so the other person sees the filter too.
 *
 * Works directly on the I420 (YUV) frame with lookup tables: Y carries
 * brightness/contrast, U/V carry colour (saturation and warm/cool tint), so
 * each pixel is one table lookup — cheap enough for live video.
 */
class CallFilterProcessor : LocalVideoTrack.ExternalVideoFrameProcessing {
    @Volatile private var yLut: ByteArray? = null
    @Volatile private var uLut: ByteArray? = null
    @Volatile private var vLut: ByteArray? = null

    /** Picks the filter; "none" makes this a pass-through. */
    fun setFilter(id: String) {
        val p = PARAMS[id]
        if (p == null) {
            yLut = null; uLut = null; vLut = null
            return
        }
        yLut = ByteArray(256) { i -> clamp(((i - 128) * p.contrast + 128) * p.brightness) }
        uLut = ByteArray(256) { i -> clamp((i - 128) * p.saturation + 128 + p.uShift) }
        vLut = ByteArray(256) { i -> clamp((i - 128) * p.saturation + 128 + p.vShift) }
    }

    override fun onFrame(frame: VideoFrame): VideoFrame {
        val ly = yLut ?: return frame
        val lu = uLut!!
        val lv = vLut!!
        val src = frame.buffer.toI420() ?: return frame
        try {
            val w = src.width
            val h = src.height
            val cw = (w + 1) / 2
            val ch = (h + 1) / 2
            // Fresh Java-heap-managed buffers each frame: the encoder may still
            // hold the previous frame, so reusing one could corrupt it.
            val dy = ByteBuffer.allocateDirect(w * h)
            val du = ByteBuffer.allocateDirect(cw * ch)
            val dv = ByteBuffer.allocateDirect(cw * ch)
            map(src.dataY, src.strideY, w, h, dy, ly)
            map(src.dataU, src.strideU, cw, ch, du, lu)
            map(src.dataV, src.strideV, cw, ch, dv, lv)
            dy.rewind(); du.rewind(); dv.rewind()
            val out = JavaI420Buffer.wrap(w, h, dy, w, du, cw, dv, cw, null)
            return VideoFrame(out, frame.rotation, frame.timestampNs)
        } finally {
            src.release()
        }
    }

    private fun map(plane: ByteBuffer, stride: Int, w: Int, h: Int, out: ByteBuffer, lut: ByteArray) {
        val row = ByteArray(w)
        for (y in 0 until h) {
            plane.position(y * stride)
            plane.get(row, 0, w)
            for (x in 0 until w) row[x] = lut[row[x].toInt() and 0xFF]
            out.put(row)
        }
    }

    private data class Params(
        val contrast: Float = 1f,
        val brightness: Float = 1f,
        val saturation: Float = 1f,
        val uShift: Float = 0f, // + = bluer
        val vShift: Float = 0f, // + = redder
    )

    companion object {
        private fun clamp(v: Float): Byte = v.toInt().coerceIn(0, 255).toByte()

        // Close YUV equivalents of the website's CSS filters (app.js CALL_FILTERS).
        private val PARAMS = mapOf(
            "mono" to Params(contrast = 1.05f, saturation = 0f),
            "warm" to Params(brightness = 1.03f, saturation = 1.3f, uShift = -10f, vShift = 12f),
            "cool" to Params(contrast = 1.03f, brightness = 1.05f, saturation = 1.15f, uShift = 12f, vShift = -8f),
            "vivid" to Params(contrast = 1.12f, saturation = 1.7f),
            "vintage" to Params(contrast = 1.1f, brightness = 0.95f, saturation = 0.55f, uShift = -14f, vShift = 12f),
            "noir" to Params(contrast = 1.45f, brightness = 0.9f, saturation = 0f),
            "soft" to Params(contrast = 0.96f, brightness = 1.08f, saturation = 1.05f),
        )
    }
}
