package vn.mangodemo.mango_offline

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.widget.*
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.min

/** Private bounded viewer: never launches an external service with a user's proof. */
class EvidenceViewerActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()
    private var renderer: PdfRenderer? = null
    private var descriptor: ParcelFileDescriptor? = null
    private var page = 0
    private lateinit var image: ImageView
    private lateinit var label: TextView
    private lateinit var previous: Button
    private lateinit var next: Button
    private var bitmap: Bitmap? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setPadding(16,32,16,16); setBackgroundColor(Color.WHITE) }
        val close = Button(this).apply { text="Đóng bằng chứng"; setOnClickListener { finish() } }; root.addView(close)
        label = TextView(this).apply { text="Đang mở tệp…"; textSize=16f }; root.addView(label)
        image = ImageView(this).apply { adjustViewBounds=true; scaleType=ImageView.ScaleType.FIT_CENTER }
        root.addView(image,LinearLayout.LayoutParams(-1,0,1f))
        val navigation=LinearLayout(this)
        previous=Button(this).apply { text="Trang trước"; setOnClickListener { show(page-1) } }
        next=Button(this).apply { text="Trang sau"; setOnClickListener { show(page+1) } }
        navigation.addView(previous,LinearLayout.LayoutParams(0,-2,1f)); navigation.addView(next,LinearLayout.LayoutParams(0,-2,1f)); root.addView(navigation)
        setContentView(root); previous.isEnabled=false; next.isEnabled=false
        executor.execute {
            try {
                val file=File(intent.getStringExtra("path") ?: error("Missing file")); val mime=intent.getStringExtra("contentType") ?: ""
                EvidencePolicy.validate(file,File(cacheDir,"fv_evidence"),mime)
                if(mime=="application/pdf") {
                    descriptor=ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY); renderer=PdfRenderer(descriptor!!)
                    require(renderer!!.pageCount>0); renderPdf(0)
                } else {
                    val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }; BitmapFactory.decodeFile(file.path,bounds)
                    require(bounds.outWidth>0 && bounds.outHeight>0)
                    var sample=1; while(bounds.outWidth/sample>1600 || bounds.outHeight/sample>1600) sample*=2
                    val b=BitmapFactory.decodeFile(file.path,BitmapFactory.Options().apply { inSampleSize=sample }) ?: error("Invalid image")
                    display(b,"Bằng chứng hình ảnh",false,false)
                }
            } catch (_:Exception) { runOnUiThread { label.text="Không đọc được tệp. Tệp có thể bị hỏng hoặc PDF được khóa." } }
        }
    }
    private fun show(index:Int) { previous.isEnabled=false; next.isEnabled=false; executor.execute { try { renderPdf(index) } catch (_:Exception) { runOnUiThread { label.text="Không đọc được trang PDF." } } } }
    private fun renderPdf(index:Int) {
        val pdf=renderer ?: return; require(index in 0 until pdf.pageCount)
        pdf.openPage(index).use { p ->
            val scale=min(1080.0/p.width,1600.0/p.height)
            val b=Bitmap.createBitmap((p.width*scale).toInt().coerceAtLeast(1),(p.height*scale).toInt().coerceAtLeast(1),Bitmap.Config.ARGB_8888)
            b.eraseColor(Color.WHITE); p.render(b,null,null,PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY); page=index
            display(b,"Trang ${index+1}/${pdf.pageCount}",index>0,index+1<pdf.pageCount)
        }
    }
    private fun display(b:Bitmap,text:String,hasPrevious:Boolean,hasNext:Boolean) { runOnUiThread {
        if(isFinishing || isDestroyed) { b.recycle(); return@runOnUiThread }
        val old=bitmap; bitmap=b; image.setImageBitmap(b); old?.recycle(); label.text=text; previous.isEnabled=hasPrevious; next.isEnabled=hasNext
    } }
    override fun onDestroy() {
        executor.execute { renderer?.close(); descriptor?.close() }; executor.shutdown()
        bitmap?.recycle(); bitmap=null; super.onDestroy()
    }
}
