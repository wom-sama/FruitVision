package vn.mangodemo.mango_offline

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import android.widget.FrameLayout
import androidx.camera.view.PreviewView

class LivePreviewView(context: Context) : FrameLayout(context) {
    data class Box(val rect: RectF, val label: String, val classId: Int?)
    val preview = PreviewView(context).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }
    private val overlay = FruitOverlay(context)
    init { addView(preview, LayoutParams(-1, -1)); addView(overlay, LayoutParams(-1, -1)) }
    fun showBoxes(boxes: List<Box>) = overlay.show(boxes)
    fun clearBox() = overlay.show(emptyList())
    private class FruitOverlay(context: Context) : View(context) {
        private var boxes: List<Box> = emptyList()
        private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(255, 210, 48); style = Paint.Style.STROKE; strokeWidth = 3 * resources.displayMetrics.density }
        private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textSize = android.util.TypedValue.applyDimension(android.util.TypedValue.COMPLEX_UNIT_SP, 16f, resources.displayMetrics) }
        private val panel = Paint().apply { color = 0xD9132C47.toInt() }
        private val colors = intArrayOf(0xFF22A06B.toInt(), 0xFF2196F3.toInt(), 0xFFFF9800.toInt(), 0xFFE53935.toInt(), 0xFF8E44AD.toInt())
        private val expire = Runnable { boxes = emptyList(); invalidate() }
        fun show(value: List<Box>) {
            require(value.size <= 64)
            removeCallbacks(expire); boxes = value.map { it.copy(rect = RectF(it.rect)) }; invalidate()
            if (boxes.isNotEmpty()) postDelayed(expire, 1000)
        }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val margin = 8 * resources.displayMetrics.density
            for (item in boxes) {
                val box = item.rect; val label = item.label
                line.color = item.classId?.let { colors[it.coerceIn(0, 4)] } ?: Color.rgb(120, 144, 156)
                canvas.drawRect(box, line)
                val left = box.left.coerceIn(0f, (width - text.measureText(label) - 2 * margin).coerceAtLeast(0f))
                val bottom = maxOf(text.textSize + 2 * margin, box.top)
                canvas.drawRect(left, bottom - text.textSize - 2 * margin, left + text.measureText(label) + 2 * margin, bottom, panel)
                canvas.drawText(label, left + margin, bottom - margin, text)
            }
        }
        override fun onDetachedFromWindow() { removeCallbacks(expire); boxes = emptyList(); super.onDetachedFromWindow() }
    }
}
