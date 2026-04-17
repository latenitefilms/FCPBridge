#import <CoreMedia/CMFormatDescription.h>
#import <CoreVideo/CVBuffer.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <Foundation/Foundation.h>
#import <MediaExtension/MEError.h>
#import <MediaExtension/MERAWProcessor.h>

#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "BRAWCommon.h"

namespace {

struct BRAWMERAWNumericSeed {
    bool hasCurrent { false };
    double current { 0.0 };
    bool hasRange { false };
    double minimum { 0.0 };
    double maximum { 0.0 };
    bool readOnly { false };
};

struct BRAWMERAWProbeResult {
    bool clipOpened { false };
    bool frameRead { false };
    std::vector<uint32_t> isoList;
    BRAWMERAWNumericSeed iso;
    BRAWMERAWNumericSeed kelvin;
    BRAWMERAWNumericSeed tint;
    BRAWMERAWNumericSeed exposure;
    BRAWMERAWNumericSeed saturation;
    BRAWMERAWNumericSeed contrast;
    BRAWMERAWNumericSeed highlights;
    BRAWMERAWNumericSeed shadows;
    std::string error;
};

static BOOL BRAWMERAWProcessorSupportsCodecType(FourCharCode codecType)
{
    switch (codecType) {
        case 'braw':
        case 'brxq':
        case 'brst':
        case 'brvn':
        case 'brs2':
        case 'brxh':
            return YES;
        default:
            return NO;
    }
}

static NSString *BRAWMERAWFourCCString(FourCharCode value)
{
    char bytes[5] = {
        (char)((value >> 24) & 0xFF),
        (char)((value >> 16) & 0xFF),
        (char)((value >> 8) & 0xFF),
        (char)(value & 0xFF),
        '\0',
    };
    return [NSString stringWithUTF8String:bytes] ?: [NSString stringWithFormat:@"0x%08X", (unsigned int)value];
}

static NSError *BRAWMERAWProcessorError(MEError code, NSString *description)
{
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (description.length) {
        userInfo[NSLocalizedDescriptionKey] = description;
    }
    return [NSError errorWithDomain:MediaExtensionErrorDomain code:code userInfo:userInfo];
}

static void BRAWMERAWProcessorFillBlack(CVPixelBufferRef pixelBuffer)
{
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    size_t planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
    if (planeCount == 0) {
        void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
        if (baseAddress) {
            memset(baseAddress, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer));
        }
    } else {
        for (size_t planeIndex = 0; planeIndex < planeCount; planeIndex++) {
            void *baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex);
            if (!baseAddress) {
                continue;
            }
            memset(baseAddress,
                   0,
                   CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex) *
                   CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex));
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

static NSString *BRAWMERAWClipPathString(CMFormatDescriptionRef formatDescription)
{
    CFStringRef path = SpliceKitBRAW::CopyPathFromFormatDescription(formatDescription);
    if (!path) {
        return nil;
    }
    NSString *result = SpliceKitBRAW::CopyNSString(path);
    CFRelease(path);
    return result;
}

static BOOL BRAWMERAWVariantToDouble(const Variant &value, double *outValue)
{
    if (!outValue) {
        return NO;
    }

    switch (value.vt) {
        case blackmagicRawVariantTypeU8:
        case blackmagicRawVariantTypeU16:
            *outValue = value.uiVal;
            return YES;
        case blackmagicRawVariantTypeS16:
            *outValue = value.iVal;
            return YES;
        case blackmagicRawVariantTypeS32:
            *outValue = value.intVal;
            return YES;
        case blackmagicRawVariantTypeU32:
            *outValue = value.uintVal;
            return YES;
        case blackmagicRawVariantTypeFloat32:
            *outValue = value.fltVal;
            return YES;
        case blackmagicRawVariantTypeFloat64:
            *outValue = value.dblVal;
            return YES;
        default:
            return NO;
    }
}

static void BRAWMERAWClampSeed(BRAWMERAWNumericSeed &seed)
{
    if (!seed.hasRange || !seed.hasCurrent) {
        return;
    }
    if (seed.current < seed.minimum) {
        seed.current = seed.minimum;
    } else if (seed.current > seed.maximum) {
        seed.current = seed.maximum;
    }
}

static void BRAWMERAWApplyClipAttributeSeed(IBlackmagicRawClipProcessingAttributes *attributes,
                                            BlackmagicRawClipProcessingAttribute attribute,
                                            BRAWMERAWNumericSeed *seed)
{
    if (!attributes || !seed) {
        return;
    }

    Variant current = {};
    Variant minimum = {};
    Variant maximum = {};
    if (VariantInit(&current) != S_OK || VariantInit(&minimum) != S_OK || VariantInit(&maximum) != S_OK) {
        VariantClear(&current);
        VariantClear(&minimum);
        VariantClear(&maximum);
        return;
    }

    if (attributes->GetClipAttribute(attribute, &current) == S_OK) {
        double value = 0.0;
        if (BRAWMERAWVariantToDouble(current, &value)) {
            seed->hasCurrent = true;
            seed->current = value;
        }
    }

    bool readOnly = false;
    if (attributes->GetClipAttributeRange(attribute, &minimum, &maximum, &readOnly) == S_OK) {
        double minValue = 0.0;
        double maxValue = 0.0;
        if (BRAWMERAWVariantToDouble(minimum, &minValue) &&
            BRAWMERAWVariantToDouble(maximum, &maxValue)) {
            seed->hasRange = true;
            seed->minimum = minValue;
            seed->maximum = maxValue;
            seed->readOnly = readOnly;
        }
    }

    VariantClear(&current);
    VariantClear(&minimum);
    VariantClear(&maximum);
    BRAWMERAWClampSeed(*seed);
}

static void BRAWMERAWApplyFrameAttributeSeed(IBlackmagicRawFrameProcessingAttributes *attributes,
                                             BlackmagicRawFrameProcessingAttribute attribute,
                                             BRAWMERAWNumericSeed *seed)
{
    if (!attributes || !seed) {
        return;
    }

    Variant current = {};
    Variant minimum = {};
    Variant maximum = {};
    if (VariantInit(&current) != S_OK || VariantInit(&minimum) != S_OK || VariantInit(&maximum) != S_OK) {
        VariantClear(&current);
        VariantClear(&minimum);
        VariantClear(&maximum);
        return;
    }

    if (attributes->GetFrameAttribute(attribute, &current) == S_OK) {
        double value = 0.0;
        if (BRAWMERAWVariantToDouble(current, &value)) {
            seed->hasCurrent = true;
            seed->current = value;
        }
    }

    bool readOnly = false;
    if (attributes->GetFrameAttributeRange(attribute, &minimum, &maximum, &readOnly) == S_OK) {
        double minValue = 0.0;
        double maxValue = 0.0;
        if (BRAWMERAWVariantToDouble(minimum, &minValue) &&
            BRAWMERAWVariantToDouble(maximum, &maxValue)) {
            seed->hasRange = true;
            seed->minimum = minValue;
            seed->maximum = maxValue;
            seed->readOnly = readOnly;
        }
    }

    VariantClear(&current);
    VariantClear(&minimum);
    VariantClear(&maximum);
    BRAWMERAWClampSeed(*seed);
}

static NSString *BRAWMERAWTruncatedDescription(id object)
{
    NSString *description = [object description] ?: @"";
    if (description.length <= 800) {
        return description;
    }
    return [[description substringToIndex:800] stringByAppendingString:@"…"];
}

static NSDictionary<NSString *, id> *BRAWMERAWPixelBufferAttributesForInputFrame(CVPixelBufferRef inputFrame)
{
    if (!inputFrame) {
        return nil;
    }
    return @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(CVPixelBufferGetPixelFormatType(inputFrame)),
        (id)kCVPixelBufferWidthKey: @(CVPixelBufferGetWidth(inputFrame)),
        (id)kCVPixelBufferHeightKey: @(CVPixelBufferGetHeight(inputFrame)),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
}

static void BRAWMERAWCopyRowBytes(const uint8_t *sourceBaseAddress,
                                  size_t sourceBytesPerRow,
                                  uint8_t *destinationBaseAddress,
                                  size_t destinationBytesPerRow,
                                  size_t height)
{
    if (!sourceBaseAddress || !destinationBaseAddress) {
        return;
    }
    size_t bytesPerRow = std::min(sourceBytesPerRow, destinationBytesPerRow);
    for (size_t row = 0; row < height; row++) {
        memcpy(destinationBaseAddress + (row * destinationBytesPerRow),
               sourceBaseAddress + (row * sourceBytesPerRow),
               bytesPerRow);
        if (destinationBytesPerRow > bytesPerRow) {
            memset(destinationBaseAddress + (row * destinationBytesPerRow) + bytesPerRow,
                   0,
                   destinationBytesPerRow - bytesPerRow);
        }
    }
}

static BOOL BRAWMERAWCopyPixelBuffer(CVPixelBufferRef sourceFrame, CVPixelBufferRef destinationFrame)
{
    if (!sourceFrame || !destinationFrame) {
        return NO;
    }

    if (CVPixelBufferGetPixelFormatType(sourceFrame) != CVPixelBufferGetPixelFormatType(destinationFrame) ||
        CVPixelBufferGetWidth(sourceFrame) != CVPixelBufferGetWidth(destinationFrame) ||
        CVPixelBufferGetHeight(sourceFrame) != CVPixelBufferGetHeight(destinationFrame)) {
        return NO;
    }

    BOOL copied = YES;
    CVPixelBufferLockBaseAddress(sourceFrame, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(destinationFrame, 0);

    size_t sourcePlaneCount = CVPixelBufferGetPlaneCount(sourceFrame);
    size_t destinationPlaneCount = CVPixelBufferGetPlaneCount(destinationFrame);
    if (sourcePlaneCount != destinationPlaneCount) {
        copied = NO;
    } else if (sourcePlaneCount == 0) {
        BRAWMERAWCopyRowBytes((const uint8_t *)CVPixelBufferGetBaseAddress(sourceFrame),
                              CVPixelBufferGetBytesPerRow(sourceFrame),
                              (uint8_t *)CVPixelBufferGetBaseAddress(destinationFrame),
                              CVPixelBufferGetBytesPerRow(destinationFrame),
                              CVPixelBufferGetHeight(sourceFrame));
    } else {
        for (size_t planeIndex = 0; planeIndex < sourcePlaneCount; planeIndex++) {
            BRAWMERAWCopyRowBytes((const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(sourceFrame, planeIndex),
                                  CVPixelBufferGetBytesPerRowOfPlane(sourceFrame, planeIndex),
                                  (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(destinationFrame, planeIndex),
                                  CVPixelBufferGetBytesPerRowOfPlane(destinationFrame, planeIndex),
                                  CVPixelBufferGetHeightOfPlane(sourceFrame, planeIndex));
        }
    }

    CVPixelBufferUnlockBaseAddress(destinationFrame, 0);
    CVPixelBufferUnlockBaseAddress(sourceFrame, kCVPixelBufferLock_ReadOnly);

    if (!copied) {
        return NO;
    }

    CFDictionaryRef attachments = CVBufferCopyAttachments(sourceFrame, kCVAttachmentMode_ShouldPropagate);
    if (attachments) {
        CVBufferSetAttachments(destinationFrame, attachments, kCVAttachmentMode_ShouldPropagate);
        CFRelease(attachments);
    }

    return YES;
}

class BRAWMERAWFrameProbeCallback final : public IBlackmagicRawCallback {
public:
    explicit BRAWMERAWFrameProbeCallback(BRAWMERAWProbeResult *probeResult)
    : _probeResult(probeResult), _semaphore(dispatch_semaphore_create(0)) {}

    dispatch_semaphore_t semaphore() const
    {
        return _semaphore;
    }

    void ReadComplete(IBlackmagicRawJob *job, HRESULT result, IBlackmagicRawFrame *frame) override
    {
        _probeResult->frameRead = (result == S_OK && frame);
        if (result == S_OK && frame) {
            IBlackmagicRawFrameProcessingAttributes *attributes = nullptr;
            if (frame->CloneFrameProcessingAttributes(&attributes) == S_OK && attributes) {
                BRAWMERAWApplyFrameAttributeSeed(attributes, blackmagicRawFrameProcessingAttributeISO, &_probeResult->iso);
                BRAWMERAWApplyFrameAttributeSeed(attributes, blackmagicRawFrameProcessingAttributeWhiteBalanceKelvin, &_probeResult->kelvin);
                BRAWMERAWApplyFrameAttributeSeed(attributes, blackmagicRawFrameProcessingAttributeWhiteBalanceTint, &_probeResult->tint);
                BRAWMERAWApplyFrameAttributeSeed(attributes, blackmagicRawFrameProcessingAttributeExposure, &_probeResult->exposure);
                attributes->Release();
            } else if (_probeResult->error.empty()) {
                _probeResult->error = "CloneFrameProcessingAttributes failed";
            }
        } else if (_probeResult->error.empty()) {
            _probeResult->error = "CreateJobReadFrame failed";
        }

        if (job) {
            job->Release();
        }
        dispatch_semaphore_signal(_semaphore);
    }

    void DecodeComplete(IBlackmagicRawJob *, HRESULT) override {}
    void ProcessComplete(IBlackmagicRawJob *, HRESULT, IBlackmagicRawProcessedImage *) override {}
    void TrimProgress(IBlackmagicRawJob *, float) override {}
    void TrimComplete(IBlackmagicRawJob *, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void *, HRESULT) override {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID *) override { return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef(void) override { return 1; }
    ULONG STDMETHODCALLTYPE Release(void) override { return 1; }

private:
    BRAWMERAWProbeResult *_probeResult;
    dispatch_semaphore_t _semaphore;
};

static BOOL BRAWMERAWProbeSDK(NSString *clipPath, BRAWMERAWProbeResult *probeResult)
{
#if !SPLICEKIT_BRAW_SDK_AVAILABLE
    if (probeResult && probeResult->error.empty()) {
        probeResult->error = "BRAW SDK headers unavailable at build time";
    }
    return NO;
#else
    if (!clipPath.length || !probeResult) {
        return NO;
    }

    std::string createFactoryError;
    IBlackmagicRawFactory *factory = SpliceKitBRAW::CreateFactory(createFactoryError);
    if (!factory) {
        probeResult->error = createFactoryError.empty() ? "CreateFactory failed" : createFactoryError;
        return NO;
    }

    IBlackmagicRaw *codec = nullptr;
    IBlackmagicRawConfiguration *configuration = nullptr;
    IBlackmagicRawClip *clip = nullptr;
    IBlackmagicRawClipProcessingAttributes *clipAttributes = nullptr;
    IBlackmagicRawJob *readJob = nullptr;
    BOOL success = NO;

    BRAWMERAWFrameProbeCallback callback(probeResult);

    do {
        HRESULT status = factory->CreateCodec(&codec);
        if (status != S_OK || !codec) {
            probeResult->error = [[SpliceKitBRAW::DescribeHRESULT(status) stringByAppendingString:@" CreateCodec failed"] UTF8String];
            break;
        }

        if (codec->QueryInterface(IID_IBlackmagicRawConfiguration, (LPVOID *)&configuration) == S_OK && configuration) {
            configuration->SetPipeline(blackmagicRawPipelineCPU, nullptr, nullptr);
        }

        status = codec->OpenClip((__bridge CFStringRef)clipPath, &clip);
        if (status != S_OK || !clip) {
            probeResult->error = [[SpliceKitBRAW::DescribeHRESULT(status) stringByAppendingString:@" OpenClip failed"] UTF8String];
            break;
        }
        probeResult->clipOpened = true;

        if (clip->CloneClipProcessingAttributes(&clipAttributes) == S_OK && clipAttributes) {
            BRAWMERAWApplyClipAttributeSeed(clipAttributes, blackmagicRawClipProcessingAttributeToneCurveSaturation, &probeResult->saturation);
            BRAWMERAWApplyClipAttributeSeed(clipAttributes, blackmagicRawClipProcessingAttributeToneCurveContrast, &probeResult->contrast);
            BRAWMERAWApplyClipAttributeSeed(clipAttributes, blackmagicRawClipProcessingAttributeToneCurveHighlights, &probeResult->highlights);
            BRAWMERAWApplyClipAttributeSeed(clipAttributes, blackmagicRawClipProcessingAttributeToneCurveShadows, &probeResult->shadows);

            uint32_t isoValues[64] = {0};
            uint32_t isoCount = sizeof(isoValues) / sizeof(isoValues[0]);
            bool isoReadOnly = false;
            if (clipAttributes->GetISOList(isoValues, &isoCount, &isoReadOnly) == S_OK && isoCount > 0) {
                probeResult->isoList.assign(isoValues, isoValues + isoCount);
                std::sort(probeResult->isoList.begin(), probeResult->isoList.end());
                probeResult->iso.hasRange = true;
                probeResult->iso.minimum = probeResult->isoList.front();
                probeResult->iso.maximum = probeResult->isoList.back();
                probeResult->iso.readOnly = isoReadOnly;
            }
        }

        status = codec->SetCallback(&callback);
        if (status != S_OK) {
            probeResult->error = [[SpliceKitBRAW::DescribeHRESULT(status) stringByAppendingString:@" SetCallback failed"] UTF8String];
            break;
        }

        status = clip->CreateJobReadFrame(0, &readJob);
        if (status != S_OK || !readJob) {
            probeResult->error = [[SpliceKitBRAW::DescribeHRESULT(status) stringByAppendingString:@" CreateJobReadFrame failed"] UTF8String];
            break;
        }

        status = readJob->Submit();
        if (status != S_OK) {
            probeResult->error = [[SpliceKitBRAW::DescribeHRESULT(status) stringByAppendingString:@" CreateJobReadFrame submit failed"] UTF8String];
            break;
        }

        if (dispatch_semaphore_wait(callback.semaphore(), dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))) != 0) {
            probeResult->error = "CreateJobReadFrame timed out";
            break;
        }

        success = probeResult->clipOpened;
    } while (false);

cleanup:
    if (clipAttributes) {
        clipAttributes->Release();
    }
    if (readJob && !probeResult->frameRead) {
        readJob->Release();
    }
    if (clip) {
        clip->Release();
    }
    if (configuration) {
        configuration->Release();
    }
    if (codec) {
        codec->Release();
    }
    if (factory) {
        factory->Release();
    }
    return success;
#endif
}

static MERAWProcessingIntegerParameter *BRAWMERAWMakeIntegerParameter(NSString *name,
                                                                      NSString *key,
                                                                      NSString *description,
                                                                      NSInteger fallbackCurrent,
                                                                      NSInteger fallbackMinimum,
                                                                      NSInteger fallbackMaximum,
                                                                      NSInteger neutralValue,
                                                                      const BRAWMERAWNumericSeed &seed)
{
    NSInteger currentValue = seed.hasCurrent ? (NSInteger)llround(seed.current) : fallbackCurrent;
    NSInteger minimumValue = seed.hasRange ? (NSInteger)floor(seed.minimum) : fallbackMinimum;
    NSInteger maximumValue = seed.hasRange ? (NSInteger)ceil(seed.maximum) : fallbackMaximum;
    if (maximumValue < minimumValue) {
        NSInteger tmp = minimumValue;
        minimumValue = maximumValue;
        maximumValue = tmp;
    }
    currentValue = MIN(MAX(currentValue, minimumValue), maximumValue);
    NSInteger cameraValue = currentValue;

    MERAWProcessingIntegerParameter *parameter =
        [[MERAWProcessingIntegerParameter alloc] initWithName:name
                                                          key:key
                                                  description:description
                                                 initialValue:currentValue
                                                      maximum:maximumValue
                                                      minimum:minimumValue
                                                 neutralValue:neutralValue
                                                  cameraValue:cameraValue];
    parameter.enabled = !seed.readOnly;
    return parameter;
}

static MERAWProcessingFloatParameter *BRAWMERAWMakeFloatParameter(NSString *name,
                                                                  NSString *key,
                                                                  NSString *description,
                                                                  float fallbackCurrent,
                                                                  float fallbackMinimum,
                                                                  float fallbackMaximum,
                                                                  float neutralValue,
                                                                  const BRAWMERAWNumericSeed &seed)
{
    float currentValue = seed.hasCurrent ? (float)seed.current : fallbackCurrent;
    float minimumValue = seed.hasRange ? (float)seed.minimum : fallbackMinimum;
    float maximumValue = seed.hasRange ? (float)seed.maximum : fallbackMaximum;
    if (maximumValue < minimumValue) {
        float tmp = minimumValue;
        minimumValue = maximumValue;
        maximumValue = tmp;
    }
    currentValue = fminf(fmaxf(currentValue, minimumValue), maximumValue);
    float cameraValue = currentValue;

    MERAWProcessingFloatParameter *parameter =
        [[MERAWProcessingFloatParameter alloc] initWithName:name
                                                        key:key
                                                description:description
                                               initialValue:currentValue
                                                    maximum:maximumValue
                                                    minimum:minimumValue
                                               neutralValue:neutralValue
                                                cameraValue:cameraValue];
    parameter.enabled = !seed.readOnly;
    return parameter;
}

static NSArray<MERAWProcessingParameter *> *BRAWMERAWBuildParameters(NSString *clipPath)
{
    BRAWMERAWProbeResult probeResult;
    if (clipPath.length) {
        BRAWMERAWProbeSDK(clipPath, &probeResult);
        SpliceKitBRAW::Log(@"rawproc",
                           @"Parameter probe path=%@ clipOpened=%d frameRead=%d error=%s",
                           clipPath,
                           probeResult.clipOpened,
                           probeResult.frameRead,
                           probeResult.error.c_str());
    }

    NSMutableArray<MERAWProcessingParameter *> *parameters = [NSMutableArray arrayWithCapacity:8];
    [parameters addObject:BRAWMERAWMakeIntegerParameter(@"ISO",
                                                        @"iso",
                                                        @"Sensor ISO",
                                                        800,
                                                        100,
                                                        25600,
                                                        800,
                                                        probeResult.iso)];
    [parameters addObject:BRAWMERAWMakeIntegerParameter(@"Color Temperature",
                                                        @"kelvin",
                                                        @"White balance in Kelvin",
                                                        5600,
                                                        2000,
                                                        10000,
                                                        5600,
                                                        probeResult.kelvin)];
    [parameters addObject:BRAWMERAWMakeFloatParameter(@"Tint",
                                                      @"tint",
                                                      @"Green / magenta white-balance tint",
                                                      0.0f,
                                                      -50.0f,
                                                      50.0f,
                                                      0.0f,
                                                      probeResult.tint)];
    [parameters addObject:BRAWMERAWMakeFloatParameter(@"Exposure",
                                                      @"exposure",
                                                      @"Exposure compensation in stops",
                                                      0.0f,
                                                      -5.0f,
                                                      5.0f,
                                                      0.0f,
                                                      probeResult.exposure)];
    [parameters addObject:BRAWMERAWMakeFloatParameter(@"Saturation",
                                                      @"saturation",
                                                      @"Color saturation",
                                                      1.0f,
                                                      0.0f,
                                                      2.0f,
                                                      1.0f,
                                                      probeResult.saturation)];
    [parameters addObject:BRAWMERAWMakeFloatParameter(@"Contrast",
                                                      @"contrast",
                                                      @"Tone-curve contrast",
                                                      1.0f,
                                                      0.0f,
                                                      2.0f,
                                                      1.0f,
                                                      probeResult.contrast)];
    [parameters addObject:BRAWMERAWMakeFloatParameter(@"Highlights",
                                                      @"highlights",
                                                      @"Highlight recovery / roll-off",
                                                      0.0f,
                                                      -1.0f,
                                                      1.0f,
                                                      0.0f,
                                                      probeResult.highlights)];
    [parameters addObject:BRAWMERAWMakeFloatParameter(@"Shadows",
                                                      @"shadows",
                                                      @"Shadow lift",
                                                      0.0f,
                                                      -1.0f,
                                                      1.0f,
                                                      0.0f,
                                                      probeResult.shadows)];
    return parameters;
}

} // namespace

@interface BRAWMERAWProcessor : NSObject <MERAWProcessor>

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFormatDescription:(CMVideoFormatDescriptionRef)formatDescription
                      pixelBufferManager:(MERAWProcessorPixelBufferManager *)pixelBufferManager
                                   error:(NSError **)error;

@property (nonatomic, readonly) NSArray<MERAWProcessingParameter *> *processingParameters;
@property (nonatomic, readonly, getter=isReadyForMoreMediaData) BOOL readyForMoreMediaData;

@end

@interface BRAWMERAWProcessorFactory : NSObject <MERAWProcessorExtension>
@end

@implementation BRAWMERAWProcessorFactory

- (id<MERAWProcessor>)processorWithFormatDescription:(CMVideoFormatDescriptionRef)formatDescription
                        extensionPixelBufferManager:(MERAWProcessorPixelBufferManager *)extensionPixelBufferManager
                                              error:(NSError **)error
{
    if (!formatDescription || !extensionPixelBufferManager) {
        if (error) {
            *error = BRAWMERAWProcessorError(MEErrorInvalidParameter,
                                            @"RAW processor requires a format description and pixel buffer manager.");
        }
        return nil;
    }

    if (CMFormatDescriptionGetMediaType(formatDescription) != kCMMediaType_Video) {
        if (error) {
            *error = BRAWMERAWProcessorError(MEErrorUnsupportedFeature,
                                            @"RAW processor only supports video format descriptions.");
        }
        return nil;
    }

    FourCharCode codecType = CMVideoFormatDescriptionGetCodecType(formatDescription);
    if (!BRAWMERAWProcessorSupportsCodecType(codecType)) {
        if (error) {
            *error = BRAWMERAWProcessorError(MEErrorUnsupportedFeature,
                                            @"RAW processor does not support this codec type.");
        }
        return nil;
    }

    return [[BRAWMERAWProcessor alloc] initWithFormatDescription:formatDescription
                                             pixelBufferManager:extensionPixelBufferManager
                                                          error:error];
}

@end

@implementation BRAWMERAWProcessor {
    CMVideoFormatDescriptionRef _formatDescription;
    MERAWProcessorPixelBufferManager *_pixelBufferManager;
    NSArray<MERAWProcessingParameter *> *_processingParameters;
    NSString *_clipPath;
    NSString *_lastLoggedParameterSnapshot;
    NSUInteger _loggedInputFrameCount;
}

- (instancetype)initWithFormatDescription:(CMVideoFormatDescriptionRef)formatDescription
                      pixelBufferManager:(MERAWProcessorPixelBufferManager *)pixelBufferManager
                                   error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _formatDescription = formatDescription ? (CMVideoFormatDescriptionRef)CFRetain(formatDescription) : nil;
    _pixelBufferManager = pixelBufferManager;
    _clipPath = BRAWMERAWClipPathString(formatDescription);

    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    if (dimensions.width <= 0 || dimensions.height <= 0) {
        if (error) {
            *error = BRAWMERAWProcessorError(MEErrorParsingFailure,
                                            @"RAW processor received invalid image dimensions.");
        }
        return nil;
    }

    _pixelBufferManager.pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(dimensions.width),
        (id)kCVPixelBufferHeightKey: @(dimensions.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    _processingParameters = BRAWMERAWBuildParameters(_clipPath);

    SpliceKitBRAW::Log(@"rawproc",
                       @"Created processor codec=%@ dimensions=%dx%d path=%@ parameterCount=%lu",
                       BRAWMERAWFourCCString(CMVideoFormatDescriptionGetCodecType(formatDescription)),
                       dimensions.width,
                       dimensions.height,
                       _clipPath ?: @"<missing>",
                       (unsigned long)_processingParameters.count);
    return self;
}

- (void)dealloc
{
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = nil;
    }
}

- (NSArray<MERAWProcessingParameter *> *)processingParameters
{
    return _processingParameters;
}

- (BOOL)isReadyForMoreMediaData
{
    return YES;
}

- (NSDictionary<NSString *, NSNumber *> *)currentParameterSnapshot
{
    NSMutableDictionary<NSString *, NSNumber *> *snapshot = [NSMutableDictionary dictionaryWithCapacity:_processingParameters.count];
    for (MERAWProcessingParameter *parameter in _processingParameters) {
        if ([parameter isKindOfClass:[MERAWProcessingIntegerParameter class]]) {
            snapshot[parameter.key] = @(((MERAWProcessingIntegerParameter *)parameter).currentValue);
        } else if ([parameter isKindOfClass:[MERAWProcessingFloatParameter class]]) {
            snapshot[parameter.key] = @(((MERAWProcessingFloatParameter *)parameter).currentValue);
        } else if ([parameter isKindOfClass:[MERAWProcessingBooleanParameter class]]) {
            snapshot[parameter.key] = @(((MERAWProcessingBooleanParameter *)parameter).currentValue);
        } else if ([parameter isKindOfClass:[MERAWProcessingListParameter class]]) {
            snapshot[parameter.key] = @(((MERAWProcessingListParameter *)parameter).currentValue);
        }
    }
    return snapshot;
}

- (void)logInputFrame:(CVPixelBufferRef)inputFrame
{
    if (!inputFrame || _loggedInputFrameCount >= 3) {
        return;
    }

    _loggedInputFrameCount += 1;
    CFDictionaryRef attachments = CVBufferCopyAttachments(inputFrame, kCVAttachmentMode_ShouldPropagate);
    SpliceKitBRAW::Log(@"rawproc",
                       @"Input frame[%lu] clip=%@ pixelFormat=%@ size=%zux%zu attachments=%@",
                       (unsigned long)_loggedInputFrameCount,
                       _clipPath ?: @"<missing>",
                       BRAWMERAWFourCCString((FourCharCode)CVPixelBufferGetPixelFormatType(inputFrame)),
                       CVPixelBufferGetWidth(inputFrame),
                       CVPixelBufferGetHeight(inputFrame),
                       BRAWMERAWTruncatedDescription((__bridge id)attachments));
    if (attachments) {
        CFRelease(attachments);
    }
}

- (void)logParameterChangesIfNeeded
{
    NSString *snapshot = BRAWMERAWTruncatedDescription([self currentParameterSnapshot]);
    if ([_lastLoggedParameterSnapshot isEqualToString:snapshot]) {
        return;
    }
    _lastLoggedParameterSnapshot = snapshot;
    SpliceKitBRAW::Log(@"rawproc",
                       @"Parameter snapshot clip=%@ values=%@",
                       _clipPath ?: @"<missing>",
                       snapshot);
}

- (void)processFrameFromImageBuffer:(CVPixelBufferRef)inputFrame
                  completionHandler:(void (^)(CVPixelBufferRef _Nullable imageBuffer,
                                              NSError * _Nullable error))completionHandler
{
    if (!completionHandler) {
        return;
    }
    if (!inputFrame) {
        completionHandler(nil, BRAWMERAWProcessorError(MEErrorInvalidParameter,
                                                       @"RAW processor received a null input frame."));
        return;
    }

    [self logInputFrame:inputFrame];
    [self logParameterChangesIfNeeded];

    _pixelBufferManager.pixelBufferAttributes = BRAWMERAWPixelBufferAttributesForInputFrame(inputFrame);

    NSError *error = nil;
    CVPixelBufferRef outputFrame = [_pixelBufferManager createPixelBufferAndReturnError:&error];
    if (!outputFrame) {
        completionHandler(nil, error ?: BRAWMERAWProcessorError(MEErrorInternalFailure,
                                                                @"RAW processor failed to allocate an output pixel buffer."));
        return;
    }

    if (!BRAWMERAWCopyPixelBuffer(inputFrame, outputFrame)) {
        BRAWMERAWProcessorFillBlack(outputFrame);
        SpliceKitBRAW::Log(@"rawproc",
                           @"Falling back to black output clip=%@ inputFormat=%@ outputFormat=%@",
                           _clipPath ?: @"<missing>",
                           BRAWMERAWFourCCString((FourCharCode)CVPixelBufferGetPixelFormatType(inputFrame)),
                           BRAWMERAWFourCCString((FourCharCode)CVPixelBufferGetPixelFormatType(outputFrame)));
    }

    completionHandler(outputFrame, nil);
    CFRelease(outputFrame);
}

@end
