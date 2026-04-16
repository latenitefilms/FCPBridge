// braw-decoder — long-lived subprocess that hosts the Blackmagic RAW SDK in
// its own clean process context. The SpliceKit host talks to it over
// stdin/stdout using a simple framed binary protocol.
//
// Invocation:
//   braw-decoder <path-to-braw-clip>
//
// Per-request wire protocol:
//   Request  (16 bytes, little-endian):
//     cmd: u32         1 = decode, 2 = exit
//     frameIndex: u32
//     scaleHint: u32   0=Full, 1=Half, 2=Quarter, 3=Eighth
//     formatHint: u32  0=RGBAU8, 1=BGRAU8
//   Response (16 bytes header + payload):
//     status: u32      0 = ok, nonzero = error code
//     width: u32
//     height: u32
//     sizeBytes: u32   payload size immediately follows
//     data[sizeBytes]  pixel bytes (only when status==0)
//
// All BRAW SDK work runs inside this process, so the callback-thread VTable
// faults that plague in-process integration inside FCP don't reproduce here.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <Foundation/Foundation.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <condition_variable>
#include <mutex>
#include <string>
#include <unistd.h>
#include <vector>

#include "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/BlackmagicRawAPI.h"

namespace {

constexpr uint32_t kCmdDecode = 1;
constexpr uint32_t kCmdExit = 2;

constexpr uint32_t kStatusOK = 0;
constexpr uint32_t kStatusBadRequest = 1;
constexpr uint32_t kStatusReadFailed = 2;
constexpr uint32_t kStatusDecodeFailed = 3;
constexpr uint32_t kStatusEmptyResource = 4;

struct DecodeContext {
    HRESULT readResult { E_FAIL };
    HRESULT processResult { E_FAIL };
    uint32_t width { 0 };
    uint32_t height { 0 };
    uint32_t sizeBytes { 0 };
    uint8_t *outputBuffer { nullptr };
    uint32_t outputBufferCapacity { 0 };
    BlackmagicRawResolutionScale scale { blackmagicRawResolutionScaleHalf };
    BlackmagicRawResourceFormat format { blackmagicRawResourceFormatRGBAU8 };
};

// Matches the probe's simpler pattern: no mutex or condition variable; the
// callbacks run synchronously during FlushJobs() on the calling thread, so we
// write context fields directly and let FlushJobs' blocking semantics do the
// synchronisation.
class Callback : public IBlackmagicRawCallback {
public:
    void Bind(DecodeContext *ctx) { _ctx = ctx; }
    void Unbind() { _ctx = nullptr; }

    // Order matches braw.probe's known-good pattern: do all vtable work on
    // frame/processedImage FIRST, then release the job. Releasing the job
    // earlier can tear down the processedImage object we're about to read.
    void ReadComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawFrame *frame) override {
        if (_ctx) _ctx->readResult = result;
        if (result == S_OK && frame) {
            frame->SetResolutionScale(_ctx->scale);
            frame->SetResourceFormat(_ctx->format);
            IBlackmagicRawJob *decodeJob = nullptr;
            HRESULT hr = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &decodeJob);
            if (hr == S_OK && decodeJob) {
                hr = decodeJob->Submit();
                if (hr != S_OK && _ctx) {
                    _ctx->processResult = hr;
                    decodeJob->Release();
                }
            } else if (_ctx) {
                _ctx->processResult = hr;
                if (decodeJob) decodeJob->Release();
            }
        }
        if (job) job->Release();
    }

    void DecodeComplete(IBlackmagicRawJob *job, HRESULT) override {
        if (job) job->Release();
    }

    void ProcessComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawProcessedImage *processedImage) override {
        if (_ctx) _ctx->processResult = result;
        if (result == S_OK && processedImage && _ctx) {
            processedImage->GetWidth(&_ctx->width);
            processedImage->GetHeight(&_ctx->height);
            processedImage->GetResourceSizeBytes(&_ctx->sizeBytes);
            // Copy pixel bytes into our caller-allocated buffer while the
            // processedImage is still alive and owned by the SDK.
            void *resource = nullptr;
            processedImage->GetResource(&resource);
            if (resource && _ctx->sizeBytes > 0 && _ctx->sizeBytes <= _ctx->outputBufferCapacity && _ctx->outputBuffer) {
                memcpy(_ctx->outputBuffer, resource, _ctx->sizeBytes);
            } else {
                _ctx->sizeBytes = 0;
            }
        }
        if (job) job->Release();
    }

    void TrimProgress(IBlackmagicRawJob *, float) override {}
    void TrimComplete(IBlackmagicRawJob *, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void *, HRESULT) override {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID *) override { return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef(void) override { return 1; }
    ULONG STDMETHODCALLTYPE Release(void) override { return 1; }

private:
    DecodeContext *_ctx { nullptr };
};

struct Runtime {
    IBlackmagicRawFactory *factory { nullptr };
    IBlackmagicRaw *codec { nullptr };
    IBlackmagicRawConfiguration *config { nullptr };
    IBlackmagicRawClip *clip { nullptr };
    Callback callback;
};

typedef IBlackmagicRawFactory *(*CreateFactoryFromPathFn)(CFStringRef);
typedef IBlackmagicRawFactory *(*CreateFactoryFn)(void);

bool OpenClip(Runtime *rt, const char *path, std::string &errorOut) {
    // Try standard SDK install first; fall back to Player app.
    static const char *binaries[] = {
        "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries/BlackmagicRawAPI.framework/BlackmagicRawAPI",
        "/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks/BlackmagicRawAPI.framework/BlackmagicRawAPI",
    };
    static const char *loadPaths[] = {
        "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries",
        "/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks",
    };

    (void)binaries;
    (void)loadPaths;
    // Only the direct factory symbol is exported from the framework itself.
    // The "FromPath" dispatch variant lives in BlackmagicRawAPIDispatch.cpp,
    // which we'd need to compile in. Link-time create is enough for the clean
    // subprocess context.
    IBlackmagicRawFactory *factory = CreateBlackmagicRawFactoryInstance();
    if (!factory) {
        errorOut = "factory creation failed";
        return false;
    }

    IBlackmagicRaw *codec = nullptr;
    if (factory->CreateCodec(&codec) != S_OK || !codec) {
        errorOut = "CreateCodec failed";
        factory->Release();
        return false;
    }

    IBlackmagicRawConfiguration *config = nullptr;
    if (codec->QueryInterface(IID_IBlackmagicRawConfiguration, (LPVOID *)&config) == S_OK && config) {
        config->SetPipeline(blackmagicRawPipelineCPU, nullptr, nullptr);
    }

    NSString *nsPath = @(path);
    IBlackmagicRawClip *clip = nullptr;
    HRESULT hr = codec->OpenClip((__bridge CFStringRef)nsPath, &clip);
    if (hr != S_OK || !clip) {
        errorOut = "OpenClip failed";
        if (config) config->Release();
        codec->Release();
        factory->Release();
        return false;
    }

    rt->factory = factory;
    rt->codec = codec;
    rt->config = config;
    rt->clip = clip;
    codec->SetCallback(&rt->callback);
    return true;
}

void CloseClip(Runtime *rt) {
    if (rt->clip) { rt->clip->Release(); rt->clip = nullptr; }
    if (rt->config) { rt->config->Release(); rt->config = nullptr; }
    if (rt->codec) { rt->codec->Release(); rt->codec = nullptr; }
    if (rt->factory) { rt->factory->Release(); rt->factory = nullptr; }
}

bool DecodeFrame(Runtime *rt, uint32_t frameIndex, uint32_t scaleHint, uint32_t formatHint,
                 DecodeContext &ctx, std::vector<uint8_t> &buffer, std::string &errorOut) {
    switch (scaleHint) {
        case 0: ctx.scale = blackmagicRawResolutionScaleFull; break;
        case 1: ctx.scale = blackmagicRawResolutionScaleHalf; break;
        case 2: ctx.scale = blackmagicRawResolutionScaleQuarter; break;
        case 3: ctx.scale = blackmagicRawResolutionScaleEighth; break;
        default: ctx.scale = blackmagicRawResolutionScaleHalf; break;
    }
    ctx.format = (formatHint == 1) ? blackmagicRawResourceFormatBGRAU8
                                    : blackmagicRawResourceFormatRGBAU8;

    // Oversize allocation for any reasonable BRAW frame at any supported scale.
    // The SDK writes into this buffer and reports the actual size in
    // ResourceSizeBytes during ProcessComplete.
    const size_t kBufferCap = 512u * 1024u * 1024u;
    if (buffer.size() < kBufferCap) buffer.resize(kBufferCap);
    ctx.outputBuffer = buffer.data();
    ctx.outputBufferCapacity = (uint32_t)buffer.size();

    rt->callback.Bind(&ctx);
    IBlackmagicRawJob *readJob = nullptr;
    HRESULT hr = rt->clip->CreateJobReadFrame(frameIndex, &readJob);
    if (hr != S_OK || !readJob) {
        rt->callback.Unbind();
        errorOut = "CreateJobReadFrame failed";
        return false;
    }
    hr = readJob->Submit();
    if (hr != S_OK) {
        readJob->Release();
        rt->callback.Unbind();
        errorOut = "Read job submit failed";
        return false;
    }

    rt->codec->FlushJobs();  // blocks until both ReadComplete and ProcessComplete run
    rt->callback.Unbind();

    if (ctx.processResult != S_OK) {
        errorOut = "ProcessComplete returned failure";
        return false;
    }
    if (ctx.sizeBytes == 0 || ctx.width == 0 || ctx.height == 0) {
        errorOut = "ProcessComplete returned empty frame";
        return false;
    }
    return true;
}

// Read exactly n bytes from stdin. Returns false on EOF or error.
bool ReadAll(void *buf, size_t n) {
    uint8_t *p = static_cast<uint8_t *>(buf);
    while (n > 0) {
        ssize_t got = read(STDIN_FILENO, p, n);
        if (got <= 0) return false;
        p += got;
        n -= (size_t)got;
    }
    return true;
}

bool WriteAll(const void *buf, size_t n) {
    const uint8_t *p = static_cast<const uint8_t *>(buf);
    while (n > 0) {
        ssize_t wrote = write(STDOUT_FILENO, p, n);
        if (wrote <= 0) return false;
        p += wrote;
        n -= (size_t)wrote;
    }
    return true;
}

void WriteResponse(uint32_t status, uint32_t w, uint32_t h, uint32_t sz, const void *bytes) {
    uint32_t header[4] = { status, w, h, sz };
    WriteAll(header, sizeof(header));
    if (sz > 0 && bytes) WriteAll(bytes, sz);
}

} // namespace

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: braw-decoder <path-to-braw>\n");
            return 2;
        }

        fprintf(stderr, "[braw-decoder] opening %s\n", argv[1]);
        Runtime rt;
        std::string error;
        if (!OpenClip(&rt, argv[1], error)) {
            fprintf(stderr, "[braw-decoder] open failed: %s\n", error.c_str());
            return 3;
        }
        fprintf(stderr, "[braw-decoder] ready\n");

        std::vector<uint8_t> buffer;
        for (;;) {
            uint32_t req[4] = {};
            if (!ReadAll(req, sizeof(req))) {
                fprintf(stderr, "[braw-decoder] stdin closed, exiting\n");
                break;
            }
            uint32_t cmd = req[0];
            fprintf(stderr, "[braw-decoder] cmd=%u frameIdx=%u scale=%u fmt=%u\n", cmd, req[1], req[2], req[3]);
            if (cmd == kCmdExit) {
                break;
            }
            if (cmd != kCmdDecode) {
                WriteResponse(kStatusBadRequest, 0, 0, 0, nullptr);
                continue;
            }
            DecodeContext ctx;
            std::string err;
            if (!DecodeFrame(&rt, req[1], req[2], req[3], ctx, buffer, err)) {
                fprintf(stderr, "[braw-decoder] decode failed: %s\n", err.c_str());
                WriteResponse(kStatusDecodeFailed, 0, 0, 0, nullptr);
                continue;
            }
            fprintf(stderr, "[braw-decoder] decoded %ux%u %u bytes\n", ctx.width, ctx.height, ctx.sizeBytes);
            WriteResponse(kStatusOK, ctx.width, ctx.height, ctx.sizeBytes, buffer.data());
        }

        CloseClip(&rt);
    }
    return 0;
}
