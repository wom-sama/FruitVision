package vn.mangodemo.mango_offline

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.File
import kotlin.math.max

internal object PhotoPreparation {
    /** Sample before decoding, orient and remove metadata. No AI model runs in the APK. */
    fun prepare(source:File,directory:File,maxEdge:Int=1024,maxBytes:Long=2L*1024*1024):File {
        require(source.length() in 1..12L*1024*1024 && maxEdge in 256..2048)
        val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }; BitmapFactory.decodeFile(source.path,bounds)
        require(bounds.outWidth>0 && bounds.outHeight>0)
        var sample=1; while(max(bounds.outWidth,bounds.outHeight)/sample>maxEdge*2) sample*=2
        var bitmap=BitmapFactory.decodeFile(source.path,BitmapFactory.Options().apply { inSampleSize=sample }) ?: error("Invalid image")
        val orientation=ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION,ExifInterface.ORIENTATION_NORMAL)
        val matrix=Matrix()
        when(orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f,1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f,-1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f,1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f,1f) }
        }
        try {
            if(!matrix.isIdentity) { val changed=Bitmap.createBitmap(bitmap,0,0,bitmap.width,bitmap.height,matrix,true); if(changed!==bitmap) bitmap.recycle(); bitmap=changed }
            val scale=maxEdge.toDouble()/max(bitmap.width,bitmap.height)
            if(scale<1) { val changed=Bitmap.createScaledBitmap(bitmap,(bitmap.width*scale).toInt().coerceAtLeast(1),(bitmap.height*scale).toInt().coerceAtLeast(1),true); if(changed!==bitmap) bitmap.recycle(); bitmap=changed }
            val output=File.createTempFile("prepared_",".jpg",directory)
            try { output.outputStream().use { require(bitmap.compress(Bitmap.CompressFormat.JPEG,85,it)) }; require(output.length() in 1..maxBytes); return output }
            catch(e:Exception) { output.delete(); throw e }
        } finally { bitmap.recycle() }
    }
}
