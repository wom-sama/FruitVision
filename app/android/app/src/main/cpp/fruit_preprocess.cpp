#include <jni.h>
#include <android/bitmap.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <new>
#include <vector>

namespace {
constexpr int precision=22, unit=1<<precision, rounding=1<<(precision-1);
struct Weights { int start; std::vector<int> values; };
std::vector<Weights> weights(int input,int output) {
    std::vector<Weights> result(output);
    const double scale=static_cast<double>(input)/output, support=std::max(scale,1.);
    for(int i=0;i<output;++i) {
        const double center=(i+.5)*scale;
        const int start=std::max(0,static_cast<int>(center-support+.5));
        const int end=std::min(input,static_cast<int>(center+support+.5));
        std::vector<double> raw(end-start);double sum=0.;
        for(int j=0;j<end-start;++j) { raw[j]=std::max(0.,1.-std::abs((start+j-center+.5)/support));sum+=raw[j]; }
        result[i].start=start;result[i].values.resize(raw.size());
        for(size_t j=0;j<raw.size();++j)result[i].values[j]=static_cast<int>(.5+raw[j]/sum*unit);
    }
    return result;
}
uint32_t sample(const uint32_t* pixels,int offset,int stride,const Weights& w) {
    int r=rounding,g=rounding,b=rounding;
    for(size_t j=0;j<w.values.size();++j) {
        const uint32_t p=pixels[offset+(w.start+static_cast<int>(j))*stride];const int k=w.values[j];
        r+=static_cast<int>((p>>16)&255)*k;g+=static_cast<int>((p>>8)&255)*k;b+=static_cast<int>(p&255)*k;
    }
    return 0xff000000u|(static_cast<uint32_t>(std::clamp(r>>precision,0,255))<<16)
        |(static_cast<uint32_t>(std::clamp(g>>precision,0,255))<<8)|std::clamp(b>>precision,0,255);
}
struct State {
    int width=0,height=0,outWidth=0,outHeight=0;
    std::vector<Weights> x,y;
    std::vector<uint32_t> source,horizontal;
};
void fail(JNIEnv* env,const char* type,const char* message) { if(!env->ExceptionCheck())env->ThrowNew(env->FindClass(type),message); }
struct PixelLock { JNIEnv* env; jobject bitmap; ~PixelLock(){AndroidBitmap_unlockPixels(env,bitmap);} };
}

extern "C" JNIEXPORT jlong JNICALL Java_vn_mangodemo_mango_1offline_NativePreprocessor_create(JNIEnv* env,jobject) {
    auto* state=new(std::nothrow) State();
    if(!state)fail(env,"java/lang/OutOfMemoryError","Native preprocessing allocation");
    return reinterpret_cast<jlong>(state);
}
extern "C" JNIEXPORT void JNICALL Java_vn_mangodemo_mango_1offline_NativePreprocessor_destroy(JNIEnv*,jobject,jlong handle) {
    delete reinterpret_cast<State*>(handle);
}
extern "C" JNIEXPORT jboolean JNICALL Java_vn_mangodemo_mango_1offline_NativePreprocessor_prepareNative(
    JNIEnv* env,jobject,jlong handle,jobject bitmap,jobject buffer,jint target,jint w,jint h,jint left,jint top) {
    auto* state=reinterpret_cast<State*>(handle);auto* out=static_cast<float*>(env->GetDirectBufferAddress(buffer));
    const jlong capacity=env->GetDirectBufferCapacity(buffer);
    if(!state||!out||target<1||target>640||w<1||h<1||w>target||h>target||left<0||top<0||left>target-w||top>target-h||capacity<12LL*target*target) {
        fail(env,"java/lang/IllegalArgumentException","Invalid native preprocessing geometry/buffer");return JNI_FALSE;
    }
    AndroidBitmapInfo info{};
    if(AndroidBitmap_getInfo(env,bitmap,&info)!=ANDROID_BITMAP_RESULT_SUCCESS) {
        fail(env,"java/lang/IllegalArgumentException","Cannot read bitmap");return JNI_FALSE;
    }
    if(info.format!=ANDROID_BITMAP_FORMAT_RGBA_8888 || (info.flags&ANDROID_BITMAP_FLAGS_IS_HARDWARE))return JNI_FALSE;
    if(!info.width||!info.height||info.width>8192||info.height>8192||static_cast<uint64_t>(info.width)*info.height>16777216||info.stride<info.width*4) {
        fail(env,"java/lang/IllegalArgumentException","Unsupported bitmap dimensions");return JNI_FALSE;
    }
    void* address=nullptr;
    if(AndroidBitmap_lockPixels(env,bitmap,&address)!=ANDROID_BITMAP_RESULT_SUCCESS) {
        fail(env,"java/lang/IllegalStateException","Cannot lock bitmap");return JNI_FALSE;
    }
    PixelLock lock{env,bitmap};
    try {
        const int width=static_cast<int>(info.width),height=static_cast<int>(info.height);
        state->source.resize(static_cast<size_t>(width)*height);
        for(int row=0;row<height;++row) {
            const auto* pixel=static_cast<const uint8_t*>(address)+static_cast<size_t>(row)*info.stride;
            for(int col=0;col<width;++col,pixel+=4) {
                // Bitmap.getPixels unpremultiplies alpha. Avoid changing its semantics.
                if(pixel[3]!=255)return JNI_FALSE;
                state->source[static_cast<size_t>(row)*width+col]=0xff000000u|(pixel[0]<<16)|(pixel[1]<<8)|pixel[2];
            }
        }
        if(width!=state->width||height!=state->height||w!=state->outWidth||h!=state->outHeight) {
            auto x=width==w?std::vector<Weights>{}:weights(width,w);
            auto y=height==h?std::vector<Weights>{}:weights(height,h);
            state->horizontal.resize(static_cast<size_t>(w)*height);
            state->x=std::move(x);state->y=std::move(y);
            state->width=width;state->height=height;state->outWidth=w;state->outHeight=h;
        }
        const uint32_t* rows=state->source.data();
        if(!state->x.empty()) {
            for(int row=0;row<height;++row)for(int col=0;col<w;++col)
                state->horizontal[static_cast<size_t>(row)*w+col]=sample(rows,row*width,1,state->x[col]);
            rows=state->horizontal.data();
        }
        const int plane=target*target;
        std::fill(out,out+3*plane,128.f/255.f);
        for(int row=0;row<h;++row)for(int col=0;col<w;++col) {
            const uint32_t p=state->y.empty()?rows[row*w+col]:sample(rows,col,w,state->y[row]);
            const int i=(row+top)*target+left+col;
            out[i]=static_cast<float>((p>>16)&255)/255.f;
            out[plane+i]=static_cast<float>((p>>8)&255)/255.f;
            out[2*plane+i]=static_cast<float>(p&255)/255.f;
        }
        return JNI_TRUE;
    } catch(const std::bad_alloc&) {
        fail(env,"java/lang/OutOfMemoryError","Native preprocessing buffer allocation");return JNI_FALSE;
    }
}

extern "C" JNIEXPORT void JNICALL Java_vn_mangodemo_mango_1offline_NativeYuvConverter_convertNative(
    JNIEnv* env,jobject,jobject bitmap,
    jobject yBuffer,jint yOffset,jint yLimit,jint yRow,jint yPixel,
    jobject uBuffer,jint uOffset,jint uLimit,jint uRow,jint uPixel,
    jobject vBuffer,jint vOffset,jint vLimit,jint vRow,jint vPixel,
    jint left,jint top,jint width,jint height,jint rotation,jboolean full,jboolean bt709) {
    const int64_t right=static_cast<int64_t>(left)+width-1,bottom=static_cast<int64_t>(top)+height-1;
    if(left<0||top<0||width<1||height<1||static_cast<int64_t>(width)*height>16000000||
        right>INT32_MAX||bottom>INT32_MAX||!(rotation==0||rotation==90||rotation==180||rotation==270)) {
        fail(env,"java/lang/IllegalArgumentException","Invalid YUV crop/rotation");return;
    }
    struct Plane { const uint8_t* data; int offset,row,pixel; };
    const auto readPlane=[&](jobject buffer,int offset,int limit,int row,int pixel,int divisor,Plane& plane) {
        if(!buffer||offset<0||limit<=offset||row<1||pixel<1)return false;
        const jlong capacity=env->GetDirectBufferCapacity(buffer);
        const auto* data=static_cast<const uint8_t*>(env->GetDirectBufferAddress(buffer));
        const int64_t last=static_cast<int64_t>(offset)+(bottom/divisor)*row+(right/divisor)*pixel;
        if(!data||capacity<limit||last>=limit)return false;
        plane={data,offset,row,pixel};return true;
    };
    Plane y{},u{},v{};
    if(!readPlane(yBuffer,yOffset,yLimit,yRow,yPixel,1,y)||
        !readPlane(uBuffer,uOffset,uLimit,uRow,uPixel,2,u)||
        !readPlane(vBuffer,vOffset,vLimit,vRow,vPixel,2,v)) {
        fail(env,"java/lang/IllegalArgumentException","YUV plane is truncated or not direct");return;
    }
    AndroidBitmapInfo info{};
    const int rotatedWidth=rotation%180==0?width:height,rotatedHeight=rotation%180==0?height:width;
    if(AndroidBitmap_getInfo(env,bitmap,&info)!=ANDROID_BITMAP_RESULT_SUCCESS||
        info.format!=ANDROID_BITMAP_FORMAT_RGBA_8888||(info.flags&ANDROID_BITMAP_FLAGS_IS_HARDWARE)||
        !info.width||!info.height||info.width>1600||info.height>1600||
        info.width>static_cast<uint32_t>(rotatedWidth)||info.height>static_cast<uint32_t>(rotatedHeight)||
        info.stride<info.width*4) {
        fail(env,"java/lang/IllegalArgumentException","Invalid YUV destination bitmap");return;
    }
    void* address=nullptr;
    if(AndroidBitmap_lockPixels(env,bitmap,&address)!=ANDROID_BITMAP_RESULT_SUCCESS) {
        fail(env,"java/lang/IllegalStateException","Cannot lock YUV destination bitmap");return;
    }
    PixelLock lock{env,bitmap};
    try {
        std::vector<int> xs(info.width),ys(info.height);
        for(uint32_t x=0;x<info.width;++x) xs[x]=static_cast<int>((2LL*x+1)*rotatedWidth/(2LL*info.width));
        for(uint32_t row=0;row<info.height;++row) ys[row]=static_cast<int>((2LL*row+1)*rotatedHeight/(2LL*info.height));
        const int rCoefficient=bt709?(full?403:459):(full?359:409);
        const int guCoefficient=bt709?(full?48:55):(full?88:100);
        const int gvCoefficient=bt709?(full?120:136):(full?183:208);
        const int bCoefficient=bt709?(full?475:541):(full?454:516);
        for(uint32_t row=0;row<info.height;++row) {
            auto* destination=static_cast<uint8_t*>(address)+static_cast<size_t>(row)*info.stride;
            const int ry=ys[row];
            for(uint32_t x=0;x<info.width;++x,destination+=4) {
                const int rx=xs[x];int sx=0,sy=0;
                switch(rotation) {
                    case 0:sx=rx;sy=ry;break;
                    case 90:sx=ry;sy=height-1-rx;break;
                    case 180:sx=width-1-rx;sy=height-1-ry;break;
                    default:sx=width-1-ry;sy=rx;
                }
                sx+=left;sy+=top;
                const int luma=y.data[static_cast<int64_t>(y.offset)+static_cast<int64_t>(sy)*y.row+static_cast<int64_t>(sx)*y.pixel];
                const int du=u.data[static_cast<int64_t>(u.offset)+static_cast<int64_t>(sy/2)*u.row+static_cast<int64_t>(sx/2)*u.pixel]-128;
                const int dv=v.data[static_cast<int64_t>(v.offset)+static_cast<int64_t>(sy/2)*v.row+static_cast<int64_t>(sx/2)*v.pixel]-128;
                const int value=full?luma*256:std::max(0,luma-16)*298;
                destination[0]=static_cast<uint8_t>(std::clamp((value+rCoefficient*dv+128)>>8,0,255));
                destination[1]=static_cast<uint8_t>(std::clamp((value-guCoefficient*du-gvCoefficient*dv+128)>>8,0,255));
                destination[2]=static_cast<uint8_t>(std::clamp((value+bCoefficient*du+128)>>8,0,255));
                destination[3]=255;
            }
        }
    } catch(const std::bad_alloc&) { fail(env,"java/lang/OutOfMemoryError","Native YUV mapping allocation"); }
}
