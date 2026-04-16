#pragma once

#include <VideoToolbox/VideoToolbox.h>
#include "CMBaseObjectSPI.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma pack(push, 4)

typedef FourCharCode FigVideoCodecType;
typedef struct OpaqueVTVideoDecoder *VTVideoDecoderRef;
typedef struct OpaqueVTVideoDecoderSession *VTVideoDecoderSession;
typedef struct OpaqueVTVideoDecoderFrame *VTVideoDecoderFrame;

typedef OSStatus (*VTVideoDecoderFunction_CreateInstance)(FourCharCode, CFAllocatorRef, VTVideoDecoderRef *);
typedef OSStatus (*VTVideoDecoderFunction_StartSession)(VTVideoDecoderRef, VTVideoDecoderSession, CMVideoFormatDescriptionRef);
typedef OSStatus (*VTVideoDecoderFunction_DecodeFrame)(VTVideoDecoderRef, VTVideoDecoderFrame, CMSampleBufferRef, VTDecodeFrameFlags, VTDecodeInfoFlags *);
typedef OSStatus (*VTVideoDecoderFunction_CopySupportedPropertyDictionary)(VTVideoDecoderRef, CFDictionaryRef *);
typedef OSStatus (*VTVideoDecoderFunction_SetProperties)(VTVideoDecoderRef, CFDictionaryRef);
typedef OSStatus (*VTVideoDecoderFunction_CopySerializableProperties)(VTVideoDecoderRef, CFDictionaryRef *);
typedef Boolean (*VTVideoDecoderFunction_CanAcceptFormatDescription)(VTVideoDecoderRef, CMVideoFormatDescriptionRef);
typedef OSStatus (*VTVideoDecoderFunction_FinishDelayedFrames)(VTVideoDecoderRef);
typedef OSStatus (*VTVideoDecoderFunction_TBD)(void);

enum {
    kVTVideoDecoder_ClassVersion_1 = 1,
    kVTVideoDecoder_ClassVersion_2 = 2,
    kVTVideoDecoder_ClassVersion_3 = 3,
};

typedef struct {
    CMBaseClassVersion version;
    VTVideoDecoderFunction_StartSession startSession;
    VTVideoDecoderFunction_DecodeFrame decodeFrame;
    VTVideoDecoderFunction_CopySupportedPropertyDictionary copySupportedPropertyDictionary;
    VTVideoDecoderFunction_SetProperties setProperties;
    VTVideoDecoderFunction_CopySerializableProperties copySerializableProperties;
    VTVideoDecoderFunction_CanAcceptFormatDescription canAcceptFormatDescription;
    VTVideoDecoderFunction_FinishDelayedFrames finishDelayedFrames;
    VTVideoDecoderFunction_TBD reserved7;
    VTVideoDecoderFunction_TBD reserved8;
    VTVideoDecoderFunction_TBD reserved9;
} VTVideoDecoderClass;

typedef struct {
    CMBaseVTable base;
    const VTVideoDecoderClass *videoDecoderClass;
} VTVideoDecoderVTable;

CMBaseClassID VTVideoDecoderGetClassID(void);
CMBaseObjectRef VTVideoDecoderGetCMBaseObject(VTVideoDecoderRef);
CVPixelBufferPoolRef VTDecoderSessionGetPixelBufferPool(VTVideoDecoderSession);
CFDictionaryRef VTDecoderSessionGetDestinationPixelBufferAttributes(VTVideoDecoderSession);
OSStatus VTDecoderSessionSetPixelBufferAttributes(VTVideoDecoderSession, CFDictionaryRef);
OSStatus VTDecoderSessionEmitDecodedFrame(VTVideoDecoderSession, VTVideoDecoderFrame, OSStatus, VTDecodeInfoFlags, CVImageBufferRef);
OSStatus VTRegisterVideoDecoder(FigVideoCodecType, VTVideoDecoderFunction_CreateInstance);
void VTRegisterVideoDecoderBundleDirectory(CFURLRef directoryURL);

#pragma pack(pop)

#ifdef __cplusplus
}
#endif
