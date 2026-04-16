#pragma once

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <Foundation/Foundation.h>
#include <string>

#include "Private/MediaToolboxSPI.h"

#if __has_include("/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/BlackmagicRawAPI.h")
#include "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/BlackmagicRawAPI.h"
#define SPLICEKIT_BRAW_SDK_AVAILABLE 1
#else
#define SPLICEKIT_BRAW_SDK_AVAILABLE 0
#endif

namespace SpliceKitBRAW {

constexpr OSType kCodecType = 'braw';

struct ClipInfo {
    uint32_t width { 0 };
    uint32_t height { 0 };
    float frameRate { 24.0f };
    uint64_t frameCount { 0 };
    CMTime frameDuration { kCMTimeInvalid };
    CMTime duration { kCMTimeInvalid };
};

void Log(NSString *component, NSString *format, ...);
NSString *DescribeOSStatus(OSStatus status);
NSString *DescribeHRESULT(HRESULT status);
NSString *CopyNSString(CFStringRef value);
CFStringRef CopyStandardizedPath(CFStringRef rawPath);
CFStringRef CopyStandardizedPathFromByteSource(MTPluginByteSourceRef byteSource);
CFStringRef CopyPathFromFormatDescription(CMFormatDescriptionRef formatDescription);
CFDictionaryRef CreatePathAtomDictionary(CFAllocatorRef allocator, CFStringRef filePath);
CMVideoFormatDescriptionRef CreateVideoFormatDescription(CFAllocatorRef allocator, CFStringRef filePath, const ClipInfo &info);
CMTime FrameDurationForRate(double frameRate);
uint64_t FrameIndexForTime(CMTime time, const ClipInfo &info);

#if SPLICEKIT_BRAW_SDK_AVAILABLE
IBlackmagicRawFactory *CreateFactory(std::string &error);
bool ReadClipInfo(CFStringRef path, ClipInfo &info, std::string &error);
#endif

} // namespace SpliceKitBRAW
