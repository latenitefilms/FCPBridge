#include "BRAWCommon.h"

#include <CoreGraphics/CGAffineTransform.h>
#include <CoreMedia/CMFormatDescription.h>
#include <CoreMedia/CMSampleBuffer.h>
#include <cmath>
#include <unistd.h>

using namespace SpliceKitBRAW;

namespace {

__attribute__((constructor))
static void BRAWFormatReaderBundleDidLoad()
{
    Log(@"reader", @"bundle loaded pid=%d", getpid());
}

#if defined(__x86_64__)
constexpr size_t kCMBasePadSize = 4;
#else
constexpr size_t kCMBasePadSize = 0;
#endif

struct AlignedBaseClass {
    uint8_t pad[kCMBasePadSize];
    CMBaseClass baseClass;
};

struct BRAWFormatReader;
struct BRAWTrackReader;
struct BRAWSampleCursor;

template<typename T>
static T *Storage(CMBaseObjectRef object)
{
    return static_cast<T *>(CMBaseObjectGetDerivedStorage(object));
}

static BRAWFormatReader *ReaderFromRef(MTPluginFormatReaderRef reader)
{
    return Storage<BRAWFormatReader>((CMBaseObjectRef)reader);
}

static BRAWTrackReader *TrackFromRef(MTPluginTrackReaderRef track)
{
    return Storage<BRAWTrackReader>((CMBaseObjectRef)track);
}

static BRAWSampleCursor *CursorFromRef(MTPluginSampleCursorRef cursor)
{
    return Storage<BRAWSampleCursor>((CMBaseObjectRef)cursor);
}

struct BRAWFormatReader {
    CFAllocatorRef allocator { nullptr };
    MTPluginByteSourceRef byteSource { nullptr };
    CFStringRef filePath { nullptr };
    ClipInfo info {};
    CMVideoFormatDescriptionRef formatDescription { nullptr };
    OSStatus status { noErr };

    BRAWFormatReader(CFAllocatorRef inAllocator, MTPluginByteSourceRef source)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
        , byteSource((MTPluginByteSourceRef)CFRetain(source))
    {
        filePath = CopyStandardizedPathFromByteSource(source);
        if (!filePath) {
            status = kMTPluginFormatReaderError_ParsingFailure;
            Log(@"reader", @"failed to resolve file path from byte source");
            return;
        }

#if SPLICEKIT_BRAW_SDK_AVAILABLE
        std::string error;
        if (!ReadClipInfo(filePath, info, error)) {
            status = kMTPluginFormatReaderError_ParsingFailure;
            Log(@"reader", @"ReadClipInfo failed for %@: %s", CopyNSString(filePath), error.c_str());
            return;
        }
#else
        status = kMTPluginFormatReaderError_ParsingFailure;
        Log(@"reader", @"BRAW SDK headers are unavailable");
        return;
#endif

        formatDescription = CreateVideoFormatDescription(allocator, filePath, info);
        if (!formatDescription) {
            status = kMTPluginFormatReaderError_ParsingFailure;
            Log(@"reader", @"failed to create format description for %@", CopyNSString(filePath));
            return;
        }

        Log(@"reader", @"prepared %@ (%ux%u %.3f fps %llu frames)",
            CopyNSString(filePath), info.width, info.height, info.frameRate, info.frameCount);
    }

    ~BRAWFormatReader()
    {
        if (formatDescription) {
            CFRelease(formatDescription);
        }
        if (filePath) {
            CFRelease(filePath);
        }
        if (byteSource) {
            CFRelease(byteSource);
        }
        if (allocator) {
            CFRelease(allocator);
        }
    }
};

struct BRAWTrackReader {
    CFAllocatorRef allocator { nullptr };
    MTPluginFormatReaderRef owner { nullptr };
    CMVideoFormatDescriptionRef formatDescription { nullptr };
    ClipInfo info {};
    MTPersistentTrackID trackID { 1 };

    BRAWTrackReader(CFAllocatorRef inAllocator, MTPluginFormatReaderRef readerRef, const ClipInfo &clipInfo, CMVideoFormatDescriptionRef description)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
        , owner((MTPluginFormatReaderRef)CFRetain(readerRef))
        , formatDescription((CMVideoFormatDescriptionRef)CFRetain(description))
        , info(clipInfo)
    {
    }

    ~BRAWTrackReader()
    {
        if (formatDescription) {
            CFRelease(formatDescription);
        }
        if (owner) {
            CFRelease(owner);
        }
        if (allocator) {
            CFRelease(allocator);
        }
    }
};

static CMItemCount TrackGetTrackEditCount(MTPluginTrackReaderRef trackRef);
static OSStatus TrackGetTrackEditWithIndex(MTPluginTrackReaderRef trackRef, CMItemCount editIndex, CMTimeMapping *mappingOut);

struct BRAWSampleCursor {
    CFAllocatorRef allocator { nullptr };
    MTPluginTrackReaderRef track { nullptr };
    uint64_t frameIndex { 0 };

    BRAWSampleCursor(CFAllocatorRef inAllocator, MTPluginTrackReaderRef trackRef, uint64_t inFrameIndex)
        : allocator((CFAllocatorRef)CFRetain(inAllocator ?: kCFAllocatorDefault))
        , track((MTPluginTrackReaderRef)CFRetain(trackRef))
        , frameIndex(inFrameIndex)
    {
    }

    ~BRAWSampleCursor()
    {
        if (track) {
            CFRelease(track);
        }
        if (allocator) {
            CFRelease(allocator);
        }
    }
};

static CFStringRef CopyReaderDebugDescription(CMBaseObjectRef)
{
    return CFSTR("SpliceKit BRAW format reader");
}

static void FinalizeReader(CMBaseObjectRef object)
{
    Storage<BRAWFormatReader>(object)->~BRAWFormatReader();
}

static OSStatus ReaderCopyProperty(CMBaseObjectRef object, CFStringRef key, CFAllocatorRef allocator, void *valueOut)
{
    BRAWFormatReader *reader = Storage<BRAWFormatReader>(object);
    if (!reader || reader->status != noErr) {
        return reader ? reader->status : kMTPluginFormatReaderError_ParsingFailure;
    }
    if (!CFEqual(key, kMTPluginFormatReaderProperty_Duration)) {
        return kCMBaseObjectError_ValueNotAvailable;
    }
    CFDictionaryRef duration = CMTimeCopyAsDictionary(reader->info.duration, allocator ?: kCFAllocatorDefault);
    if (!duration) {
        return kCMBaseObjectError_ValueNotAvailable;
    }
    *reinterpret_cast<CFDictionaryRef *>(valueOut) = duration;
    return noErr;
}

static const AlignedBaseClass kReaderBaseClass = {
    {},
    {
        kCMBaseObject_ClassVersion_1,
        sizeof(BRAWFormatReader),
        nullptr,
        nullptr,
        FinalizeReader,
        CopyReaderDebugDescription,
        ReaderCopyProperty,
        nullptr,
        nullptr,
        nullptr,
    }
};

static OSStatus ReaderCopyTrackArray(MTPluginFormatReaderRef readerRef, CFArrayRef *trackArrayOut);

static const MTPluginFormatReaderClass kReaderClass = {
    kMTPluginFormatReader_ClassVersion_1,
    ReaderCopyTrackArray,
    nullptr,
};

static const MTPluginFormatReaderVTable kReaderVTable = {
    { nullptr, &kReaderBaseClass.baseClass },
    &kReaderClass,
};

static CFStringRef CopyTrackDebugDescription(CMBaseObjectRef)
{
    return CFSTR("SpliceKit BRAW track reader");
}

static void FinalizeTrack(CMBaseObjectRef object)
{
    Storage<BRAWTrackReader>(object)->~BRAWTrackReader();
}

static OSStatus TrackCopyProperty(CMBaseObjectRef object, CFStringRef key, CFAllocatorRef allocator, void *valueOut)
{
    BRAWTrackReader *track = Storage<BRAWTrackReader>(object);
    if (!track) {
        return kCMBaseObjectError_ValueNotAvailable;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_Enabled)) {
        *reinterpret_cast<CFBooleanRef *>(valueOut) = kCFBooleanTrue;
        return noErr;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_FormatDescriptionArray)) {
        const void *values[1] = { track->formatDescription };
        *reinterpret_cast<CFArrayRef *>(valueOut) = CFArrayCreate(
            allocator ?: track->allocator,
            values,
            1,
            &kCFTypeArrayCallBacks);
        return *reinterpret_cast<CFArrayRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_Dimensions)) {
        int32_t dimensions[2] = {
            (int32_t)track->info.width,
            (int32_t)track->info.height,
        };
        *reinterpret_cast<CFDataRef *>(valueOut) = CFDataCreate(
            allocator ?: track->allocator,
            reinterpret_cast<const UInt8 *>(dimensions),
            (CFIndex)sizeof(dimensions));
        return *reinterpret_cast<CFDataRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_NominalFrameRate)) {
        float rate = track->info.frameRate;
        *reinterpret_cast<CFNumberRef *>(valueOut) = CFNumberCreate(
            allocator ?: track->allocator,
            kCFNumberFloat32Type,
            &rate);
        return *reinterpret_cast<CFNumberRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_NaturalTimescale)) {
        int32_t timescale = track->info.frameDuration.timescale > 0 ? track->info.frameDuration.timescale : 600000;
        *reinterpret_cast<CFNumberRef *>(valueOut) = CFNumberCreate(
            allocator ?: track->allocator,
            kCFNumberSInt32Type,
            &timescale);
        return *reinterpret_cast<CFNumberRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_UneditedDuration)) {
        *reinterpret_cast<CFDictionaryRef *>(valueOut) = CMTimeCopyAsDictionary(
            track->info.duration,
            allocator ?: track->allocator);
        return *reinterpret_cast<CFDictionaryRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_TotalSampleDataLength)) {
        int64_t totalLength = (int64_t)track->info.frameCount * (int64_t)sizeof(uint32_t);
        *reinterpret_cast<CFNumberRef *>(valueOut) = CFNumberCreate(
            allocator ?: track->allocator,
            kCFNumberSInt64Type,
            &totalLength);
        return *reinterpret_cast<CFNumberRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_EstimatedDataRate)) {
        Float64 bytesPerFrame = sizeof(uint32_t);
        Float64 dataRate = bytesPerFrame * 8.0 * (track->info.frameRate > 0.0 ? track->info.frameRate : 24.0);
        *reinterpret_cast<CFNumberRef *>(valueOut) = CFNumberCreate(
            allocator ?: track->allocator,
            kCFNumberFloat64Type,
            &dataRate);
        return *reinterpret_cast<CFNumberRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }

    if (CFEqual(key, kMTPluginTrackReaderProperty_PreferredTransform)) {
        CGAffineTransform identity = { 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 };
        *reinterpret_cast<CFDataRef *>(valueOut) = CFDataCreate(
            allocator ?: track->allocator,
            reinterpret_cast<const UInt8 *>(&identity),
            (CFIndex)sizeof(identity));
        return *reinterpret_cast<CFDataRef *>(valueOut) ? noErr : kCMBaseObjectError_ValueNotAvailable;
    }

    return kCMBaseObjectError_ValueNotAvailable;
}

static const AlignedBaseClass kTrackBaseClass = {
    {},
    {
        kCMBaseObject_ClassVersion_1,
        sizeof(BRAWTrackReader),
        nullptr,
        nullptr,
        FinalizeTrack,
        CopyTrackDebugDescription,
        TrackCopyProperty,
        nullptr,
        nullptr,
        nullptr,
    }
};

static OSStatus TrackGetTrackInfo(MTPluginTrackReaderRef trackRef, MTPersistentTrackID *trackIDOut, CMMediaType *mediaTypeOut);
static OSStatus TrackCreateCursorAtPresentationTime(MTPluginTrackReaderRef trackRef, CMTime time, MTPluginSampleCursorRef *cursorOut);
static OSStatus TrackCreateCursorAtFirst(MTPluginTrackReaderRef trackRef, MTPluginSampleCursorRef *cursorOut);
static OSStatus TrackCreateCursorAtLast(MTPluginTrackReaderRef trackRef, MTPluginSampleCursorRef *cursorOut);

static const MTPluginTrackReaderClass kTrackClass = {
    kMTPluginTrackReader_ClassVersion_1,
    TrackGetTrackInfo,
    TrackGetTrackEditCount,
    TrackGetTrackEditWithIndex,
    TrackCreateCursorAtPresentationTime,
    TrackCreateCursorAtFirst,
    TrackCreateCursorAtLast,
};

static const MTPluginTrackReaderVTable kTrackVTable = {
    { nullptr, &kTrackBaseClass.baseClass },
    &kTrackClass,
};

static CFStringRef CopyCursorDebugDescription(CMBaseObjectRef)
{
    return CFSTR("SpliceKit BRAW sample cursor");
}

static void FinalizeCursor(CMBaseObjectRef object)
{
    Storage<BRAWSampleCursor>(object)->~BRAWSampleCursor();
}

static const BRAWTrackReader *TrackForCursor(const BRAWSampleCursor *cursor)
{
    return cursor ? TrackFromRef(cursor->track) : nullptr;
}

static uint64_t ClampFrameIndex(const BRAWTrackReader *track, uint64_t frameIndex)
{
    if (!track || track->info.frameCount == 0) {
        return 0;
    }
    return std::min(frameIndex, track->info.frameCount - 1);
}

static CMTime PresentationTimeForFrame(const BRAWTrackReader *track, uint64_t frameIndex)
{
    return CMTimeMultiply(track->info.frameDuration, (int32_t)frameIndex);
}

static OSStatus CursorCopyProperty(CMBaseObjectRef, CFStringRef, CFAllocatorRef, void *)
{
    return kCMBaseObjectError_ValueNotAvailable;
}

static const AlignedBaseClass kCursorBaseClass = {
    {},
    {
        kCMBaseObject_ClassVersion_1,
        sizeof(BRAWSampleCursor),
        nullptr,
        nullptr,
        FinalizeCursor,
        CopyCursorDebugDescription,
        CursorCopyProperty,
        nullptr,
        nullptr,
        nullptr,
    }
};

static OSStatus CursorCopy(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorRef *cursorOut);
static OSStatus CursorStepInDecodeOrder(MTPluginSampleCursorRef cursorRef, int64_t steps, int64_t *stepsTaken);
static OSStatus CursorStepInPresentationOrder(MTPluginSampleCursorRef cursorRef, int64_t steps, int64_t *stepsTaken);
static OSStatus CursorStepByDecodeTime(MTPluginSampleCursorRef cursorRef, CMTime delta, Boolean *wasPinned);
static OSStatus CursorStepByPresentationTime(MTPluginSampleCursorRef cursorRef, CMTime delta, Boolean *wasPinned);
static CFComparisonResult CursorCompareInDecodeOrder(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorRef otherRef);
static OSStatus CursorGetSampleTiming(MTPluginSampleCursorRef cursorRef, CMSampleTimingInfo *timingOut);
static OSStatus CursorGetSyncInfo(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorSyncInfo *syncInfoOut);
static OSStatus CursorCopyFormatDescription(MTPluginSampleCursorRef cursorRef, CMFormatDescriptionRef *formatDescriptionOut);
static OSStatus CursorCopySampleLocation(MTPluginSampleCursorRef, MTPluginSampleCursorStorageRange *, MTPluginByteSourceRef *);
static OSStatus CursorCreateSampleBuffer(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorRef, CMSampleBufferRef *sampleBufferOut);
static OSStatus CursorGetPlayableHorizon(MTPluginSampleCursorRef cursorRef, CMTime *horizonOut);

static const MTPluginSampleCursorClass kCursorClass = {
    kMTPluginSampleCursor_ClassVersion_4,
    CursorCopy,
    CursorStepInDecodeOrder,
    CursorStepInPresentationOrder,
    CursorStepByDecodeTime,
    CursorStepByPresentationTime,
    CursorCompareInDecodeOrder,
    CursorGetSampleTiming,
    CursorGetSyncInfo,
    nullptr,
    nullptr,
    CursorCopySampleLocation,
    nullptr,
    CursorCopyFormatDescription,
    CursorCreateSampleBuffer,
    nullptr,
    nullptr,
    nullptr,
    CursorGetPlayableHorizon,
};

static const MTPluginSampleCursorVTable kCursorVTable = {
    { nullptr, &kCursorBaseClass.baseClass },
    &kCursorClass,
    nullptr,
};

static OSStatus CreateTrackReader(CFAllocatorRef allocator, MTPluginFormatReaderRef readerRef, const ClipInfo &info, CMVideoFormatDescriptionRef description, MTPluginTrackReaderRef *trackOut)
{
    CMBaseObjectRef object = nullptr;
    OSStatus status = CMDerivedObjectCreate(
        allocator ?: kCFAllocatorDefault,
        &kTrackVTable.base,
        MTPluginTrackReaderGetClassID(),
        &object);
    if (status != noErr || !object) {
        return status ? status : kMTPluginFormatReaderError_AllocationFailure;
    }

    new (Storage<BRAWTrackReader>(object)) BRAWTrackReader(allocator, readerRef, info, description);
    *trackOut = reinterpret_cast<MTPluginTrackReaderRef>(object);
    return noErr;
}

static OSStatus CreateCursor(CFAllocatorRef allocator, MTPluginTrackReaderRef trackRef, uint64_t frameIndex, MTPluginSampleCursorRef *cursorOut)
{
    CMBaseObjectRef object = nullptr;
    OSStatus status = CMDerivedObjectCreate(
        allocator ?: kCFAllocatorDefault,
        &kCursorVTable.base,
        MTPluginSampleCursorGetClassID(),
        &object);
    if (status != noErr || !object) {
        return status ? status : kMTPluginFormatReaderError_AllocationFailure;
    }

    new (Storage<BRAWSampleCursor>(object)) BRAWSampleCursor(allocator, trackRef, frameIndex);
    *cursorOut = reinterpret_cast<MTPluginSampleCursorRef>(object);
    return noErr;
}

static OSStatus ReaderCopyTrackArray(MTPluginFormatReaderRef readerRef, CFArrayRef *trackArrayOut)
{
    if (!trackArrayOut) {
        return paramErr;
    }
    BRAWFormatReader *reader = ReaderFromRef(readerRef);
    if (!reader) {
        return kMTPluginFormatReaderError_ParsingFailure;
    }
    if (reader->status != noErr) {
        return reader->status;
    }

    Log(@"reader", @"copyTrackArray for %@", CopyNSString(reader->filePath));

    MTPluginTrackReaderRef track = nullptr;
    OSStatus status = CreateTrackReader(reader->allocator, readerRef, reader->info, reader->formatDescription, &track);
    if (status != noErr || !track) {
        return status ? status : kMTPluginFormatReaderError_AllocationFailure;
    }

    const void *values[1] = { track };
    *trackArrayOut = CFArrayCreate(reader->allocator, values, 1, &kCFTypeArrayCallBacks);
    CFRelease(track);
    return *trackArrayOut ? noErr : kMTPluginFormatReaderError_AllocationFailure;
}

static OSStatus TrackGetTrackInfo(MTPluginTrackReaderRef trackRef, MTPersistentTrackID *trackIDOut, CMMediaType *mediaTypeOut)
{
    BRAWTrackReader *track = TrackFromRef(trackRef);
    if (!track || !trackIDOut || !mediaTypeOut) {
        return paramErr;
    }
    *trackIDOut = track->trackID;
    *mediaTypeOut = kCMMediaType_Video;
    return noErr;
}

static CMItemCount TrackGetTrackEditCount(MTPluginTrackReaderRef trackRef)
{
    BRAWTrackReader *track = TrackFromRef(trackRef);
    return track ? 1 : 0;
}

static OSStatus TrackGetTrackEditWithIndex(MTPluginTrackReaderRef trackRef, CMItemCount editIndex, CMTimeMapping *mappingOut)
{
    BRAWTrackReader *track = TrackFromRef(trackRef);
    if (!track || !mappingOut || editIndex != 0) {
        return paramErr;
    }

    mappingOut->source.start = kCMTimeZero;
    mappingOut->source.duration = track->info.duration;
    mappingOut->target = mappingOut->source;
    return noErr;
}

static OSStatus TrackCreateCursorAtPresentationTime(MTPluginTrackReaderRef trackRef, CMTime time, MTPluginSampleCursorRef *cursorOut)
{
    if (!cursorOut) {
        return paramErr;
    }
    BRAWTrackReader *track = TrackFromRef(trackRef);
    if (!track) {
        return kMTPluginSampleCursorError_NoSamples;
    }
    uint64_t frameIndex = FrameIndexForTime(time, track->info);
    return CreateCursor(track->allocator, trackRef, frameIndex, cursorOut);
}

static OSStatus TrackCreateCursorAtFirst(MTPluginTrackReaderRef trackRef, MTPluginSampleCursorRef *cursorOut)
{
    BRAWTrackReader *track = TrackFromRef(trackRef);
    if (!track || !cursorOut) {
        return paramErr;
    }
    return CreateCursor(track->allocator, trackRef, 0, cursorOut);
}

static OSStatus TrackCreateCursorAtLast(MTPluginTrackReaderRef trackRef, MTPluginSampleCursorRef *cursorOut)
{
    BRAWTrackReader *track = TrackFromRef(trackRef);
    if (!track || !cursorOut) {
        return paramErr;
    }
    uint64_t lastFrame = track && track->info.frameCount ? track->info.frameCount - 1 : 0;
    return CreateCursor(track->allocator, trackRef, lastFrame, cursorOut);
}

static OSStatus CursorCopy(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorRef *cursorOut)
{
    BRAWSampleCursor *cursor = CursorFromRef(cursorRef);
    if (!cursor || !cursorOut) {
        return paramErr;
    }
    return CreateCursor(cursor->allocator, cursor->track, cursor->frameIndex, cursorOut);
}

static OSStatus StepCursor(BRAWSampleCursor *cursor, int64_t steps, int64_t *stepsTaken)
{
    const BRAWTrackReader *track = TrackForCursor(cursor);
    if (!track || !stepsTaken) {
        return paramErr;
    }
    if (!track->info.frameCount) {
        *stepsTaken = 0;
        return kMTPluginSampleCursorError_NoSamples;
    }
    int64_t target = (int64_t)cursor->frameIndex + steps;
    target = std::max<int64_t>(0, std::min<int64_t>(target, (int64_t)track->info.frameCount - 1));
    *stepsTaken = target - (int64_t)cursor->frameIndex;
    cursor->frameIndex = (uint64_t)target;
    return noErr;
}

static OSStatus CursorStepInDecodeOrder(MTPluginSampleCursorRef cursorRef, int64_t steps, int64_t *stepsTaken)
{
    return StepCursor(CursorFromRef(cursorRef), steps, stepsTaken);
}

static OSStatus CursorStepInPresentationOrder(MTPluginSampleCursorRef cursorRef, int64_t steps, int64_t *stepsTaken)
{
    return StepCursor(CursorFromRef(cursorRef), steps, stepsTaken);
}

static OSStatus StepCursorByTime(BRAWSampleCursor *cursor, CMTime delta, Boolean *wasPinned)
{
    const BRAWTrackReader *track = TrackForCursor(cursor);
    if (!track || !wasPinned) {
        return paramErr;
    }
    if (!track->info.frameCount || !CMTIME_IS_NUMERIC(track->info.frameDuration)) {
        *wasPinned = true;
        return kMTPluginSampleCursorError_NoSamples;
    }
    Float64 seconds = CMTimeGetSeconds(delta);
    int64_t steps = (int64_t)llround(seconds * track->info.frameRate);
    int64_t taken = 0;
    OSStatus status = StepCursor(cursor, steps, &taken);
    *wasPinned = (taken != steps);
    return status;
}

static OSStatus CursorStepByDecodeTime(MTPluginSampleCursorRef cursorRef, CMTime delta, Boolean *wasPinned)
{
    return StepCursorByTime(CursorFromRef(cursorRef), delta, wasPinned);
}

static OSStatus CursorStepByPresentationTime(MTPluginSampleCursorRef cursorRef, CMTime delta, Boolean *wasPinned)
{
    return StepCursorByTime(CursorFromRef(cursorRef), delta, wasPinned);
}

static CFComparisonResult CursorCompareInDecodeOrder(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorRef otherRef)
{
    BRAWSampleCursor *cursor = CursorFromRef(cursorRef);
    BRAWSampleCursor *other = CursorFromRef(otherRef);
    if (!cursor || !other) {
        return kCFCompareLessThan;
    }
    if (cursor->track != other->track) {
        return kCFCompareLessThan;
    }
    if (cursor->frameIndex < other->frameIndex) {
        return kCFCompareLessThan;
    }
    if (cursor->frameIndex > other->frameIndex) {
        return kCFCompareGreaterThan;
    }
    return kCFCompareEqualTo;
}

static OSStatus CursorGetSampleTiming(MTPluginSampleCursorRef cursorRef, CMSampleTimingInfo *timingOut)
{
    BRAWSampleCursor *cursor = CursorFromRef(cursorRef);
    const BRAWTrackReader *track = TrackForCursor(cursor);
    if (!cursor || !track || !timingOut) {
        return paramErr;
    }
    timingOut->duration = track->info.frameDuration;
    timingOut->presentationTimeStamp = PresentationTimeForFrame(track, ClampFrameIndex(track, cursor->frameIndex));
    timingOut->decodeTimeStamp = timingOut->presentationTimeStamp;
    return noErr;
}

static OSStatus CursorGetSyncInfo(MTPluginSampleCursorRef, MTPluginSampleCursorSyncInfo *syncInfoOut)
{
    if (!syncInfoOut) {
        return paramErr;
    }
    syncInfoOut->fullSync = true;
    syncInfoOut->partialSync = false;
    syncInfoOut->droppable = false;
    return noErr;
}

static OSStatus CursorCopyFormatDescription(MTPluginSampleCursorRef cursorRef, CMFormatDescriptionRef *formatDescriptionOut)
{
    BRAWSampleCursor *cursor = CursorFromRef(cursorRef);
    const BRAWTrackReader *track = TrackForCursor(cursor);
    if (!track || !formatDescriptionOut) {
        return paramErr;
    }
    *formatDescriptionOut = (CMFormatDescriptionRef)CFRetain(track->formatDescription);
    return noErr;
}

static OSStatus CursorCopySampleLocation(MTPluginSampleCursorRef, MTPluginSampleCursorStorageRange *, MTPluginByteSourceRef *)
{
    return kCMBaseObjectError_ValueNotAvailable;
}

static OSStatus CursorCreateSampleBuffer(MTPluginSampleCursorRef cursorRef, MTPluginSampleCursorRef, CMSampleBufferRef *sampleBufferOut)
{
    BRAWSampleCursor *cursor = CursorFromRef(cursorRef);
    const BRAWTrackReader *track = TrackForCursor(cursor);
    if (!cursor || !track || !sampleBufferOut) {
        return paramErr;
    }

    uint32_t frameIndex = (uint32_t)ClampFrameIndex(track, cursor->frameIndex);
    CMBlockBufferRef blockBuffer = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        track->allocator,
        nullptr,
        sizeof(frameIndex),
        kCFAllocatorDefault,
        nullptr,
        0,
        sizeof(frameIndex),
        0,
        &blockBuffer);
    if (status != noErr || !blockBuffer) {
        return status ? status : kMTPluginFormatReaderError_AllocationFailure;
    }

    status = CMBlockBufferReplaceDataBytes(&frameIndex, blockBuffer, 0, sizeof(frameIndex));
    if (status != noErr) {
        CFRelease(blockBuffer);
        return status;
    }

    CMSampleTimingInfo timing = {
        .duration = track->info.frameDuration,
        .presentationTimeStamp = PresentationTimeForFrame(track, frameIndex),
        .decodeTimeStamp = PresentationTimeForFrame(track, frameIndex),
    };
    size_t sampleSize = sizeof(frameIndex);
    status = CMSampleBufferCreateReady(
        track->allocator,
        blockBuffer,
        track->formatDescription,
        1,
        1,
        &timing,
        1,
        &sampleSize,
        sampleBufferOut);
    CFRelease(blockBuffer);
    return status;
}

static OSStatus CursorGetPlayableHorizon(MTPluginSampleCursorRef cursorRef, CMTime *horizonOut)
{
    BRAWSampleCursor *cursor = CursorFromRef(cursorRef);
    const BRAWTrackReader *track = TrackForCursor(cursor);
    if (!cursor || !track || !horizonOut) {
        return paramErr;
    }
    uint64_t remainingFrames = 0;
    if (track->info.frameCount > cursor->frameIndex) {
        remainingFrames = track->info.frameCount - cursor->frameIndex;
    }
    *horizonOut = CMTimeMultiply(track->info.frameDuration, (int32_t)remainingFrames);
    return noErr;
}

} // namespace

extern "C" __attribute__((visibility("default")))
OSStatus BRAWPluginFormatReader_CreateInstance(
    MTPluginByteSourceRef byteSource,
    CFAllocatorRef allocator,
    CFDictionaryRef,
    MTPluginFormatReaderRef *readerOut)
{
    if (!byteSource || !readerOut) {
        return paramErr;
    }

    CFStringRef debugPath = CopyStandardizedPathFromByteSource(byteSource);
    Log(@"reader", @"factory createInstance path=%@", CopyNSString(debugPath));
    if (debugPath) {
        CFRelease(debugPath);
    }

    CMBaseObjectRef object = nullptr;
    OSStatus status = CMDerivedObjectCreate(
        allocator ?: kCFAllocatorDefault,
        &kReaderVTable.base,
        MTPluginFormatReaderGetClassID(),
        &object);
    if (status != noErr || !object) {
        return status ? status : kMTPluginFormatReaderError_AllocationFailure;
    }

    new (Storage<BRAWFormatReader>(object)) BRAWFormatReader(allocator, byteSource);
    *readerOut = reinterpret_cast<MTPluginFormatReaderRef>(object);
    return noErr;
}
