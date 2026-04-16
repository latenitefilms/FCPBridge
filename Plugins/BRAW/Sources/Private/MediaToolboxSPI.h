#pragma once

#include <CoreMedia/CMFormatDescription.h>
#include <CoreMedia/CMSampleBuffer.h>
#include "CMBaseObjectSPI.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    kMTPluginFormatReaderError_AllocationFailure = -16501,
    kMTPluginFormatReaderError_ParsingFailure = -16503,
    kMTPluginSampleCursorError_NoSamples = -16507,
    kMTPluginSampleCursorError_LocationNotAvailable = -16508,
};

enum {
    kMTPluginFormatReader_ClassVersion_1 = 1,
};

enum {
    kMTPluginSampleCursor_ClassVersion_3 = 3,
    kMTPluginSampleCursor_ClassVersion_4 = 4,
};

enum {
    kMTPluginTrackReader_ClassVersion_1 = 1,
};

typedef CMPersistentTrackID MTPersistentTrackID;
typedef int32_t MTPluginSampleCursorReorderingBoundary;
typedef struct OpaqueMTPluginByteSource *MTPluginByteSourceRef;
typedef struct OpaqueMTPluginFormatReader *MTPluginFormatReaderRef;
typedef struct OpaqueMTPluginSampleCursor *MTPluginSampleCursorRef;
typedef struct OpaqueMTPluginTrackReader *MTPluginTrackReaderRef;

typedef struct {
    int64_t offset;
    int64_t length;
} MTPluginSampleCursorStorageRange;

typedef struct {
    int64_t chunkSampleCount;
    Boolean chunkHasUniformSampleSizes;
    Boolean chunkHasUniformSampleDurations;
    Boolean chunkHasUniformFormatDescriptions;
    char pad[5];
} MTPluginSampleCursorChunkInfo;

typedef struct {
    Boolean fullSync;
    Boolean partialSync;
    Boolean droppable;
} MTPluginSampleCursorSyncInfo;

typedef struct {
    Boolean sampleIndicatesWhetherItHasDependentSamples;
    Boolean sampleHasDependentSamples;
    Boolean sampleIndicatesWhetherItDependsOnOthers;
    Boolean sampleDependsOnOthers;
    Boolean sampleIndicatesWhetherItHasRedundantCoding;
    Boolean sampleHasRedundantCoding;
} MTPluginSampleCursorDependencyInfo;

typedef OSStatus (*MTPluginFormatReaderFunction_CopyTrackArray)(MTPluginFormatReaderRef, CFArrayRef *);
typedef OSStatus (*MTPluginFormatReaderFunction_ParseAdditionalFragments)(MTPluginFormatReaderRef, uint32_t, uint32_t *);
typedef OSStatus (*MTPluginSampleCursorFunction_Copy)(MTPluginSampleCursorRef, MTPluginSampleCursorRef *);
typedef OSStatus (*MTPluginSampleCursorFunction_StepInDecodeOrderAndReportStepsTaken)(MTPluginSampleCursorRef, int64_t, int64_t *);
typedef OSStatus (*MTPluginSampleCursorFunction_StepInPresentationOrderAndReportStepsTaken)(MTPluginSampleCursorRef, int64_t, int64_t *);
typedef OSStatus (*MTPluginSampleCursorFunction_StepByDecodeTime)(MTPluginSampleCursorRef, CMTime, Boolean *);
typedef OSStatus (*MTPluginSampleCursorFunction_StepByPresentationTime)(MTPluginSampleCursorRef, CMTime, Boolean *);
typedef CFComparisonResult (*MTPluginSampleCursorFunction_CompareInDecodeOrder)(MTPluginSampleCursorRef, MTPluginSampleCursorRef);
typedef OSStatus (*MTPluginSampleCursorFunction_GetSampleTiming)(MTPluginSampleCursorRef, CMSampleTimingInfo *);
typedef OSStatus (*MTPluginSampleCursorFunction_GetSyncInfo)(MTPluginSampleCursorRef, MTPluginSampleCursorSyncInfo *);
typedef OSStatus (*MTPluginSampleCursorFunction_GetDependencyInfo)(MTPluginSampleCursorRef, MTPluginSampleCursorDependencyInfo *);
typedef Boolean (*MTPluginSampleCursorFunction_TestReorderingBoundary)(MTPluginSampleCursorRef, MTPluginSampleCursorRef, MTPluginSampleCursorReorderingBoundary);
typedef OSStatus (*MTPluginSampleCursorFunction_CopySampleLocation)(MTPluginSampleCursorRef, MTPluginSampleCursorStorageRange *, MTPluginByteSourceRef *);
typedef OSStatus (*MTPluginSampleCursorFunction_CopyChunkDetails)(MTPluginSampleCursorRef, MTPluginByteSourceRef *, MTPluginSampleCursorStorageRange *, MTPluginSampleCursorChunkInfo *, CMItemCount *);
typedef OSStatus (*MTPluginSampleCursorFunction_CopyFormatDescription)(MTPluginSampleCursorRef, CMFormatDescriptionRef *);
typedef OSStatus (*MTPluginSampleCursorFunction_CreateSampleBuffer)(MTPluginSampleCursorRef, MTPluginSampleCursorRef, CMSampleBufferRef *);
typedef OSStatus (*MTPluginSampleCursorFunction_CopyUnrefinedSampleLocation)(MTPluginSampleCursorRef, MTPluginSampleCursorStorageRange *, MTPluginSampleCursorStorageRange *, MTPluginByteSourceRef *);
typedef OSStatus (*MTPluginSampleCursorFunction_RefineSampleLocation)(MTPluginSampleCursorRef, MTPluginSampleCursorStorageRange, const uint8_t *, size_t, MTPluginSampleCursorStorageRange *);
typedef OSStatus (*MTPluginSampleCursorFunction_CopyExtendedSampleDependencyAttributes)(MTPluginSampleCursorRef, CFDictionaryRef *);
typedef OSStatus (*MTPluginSampleCursorFunction_GetPlayableHorizon)(MTPluginSampleCursorRef, CMTime *);
typedef OSStatus (*MTPluginTrackReaderFunction_GetTrackInfo)(MTPluginTrackReaderRef, MTPersistentTrackID *, CMMediaType *);
typedef CMItemCount (*MTPluginTrackReaderFunction_GetTrackEditCount)(MTPluginTrackReaderRef);
typedef OSStatus (*MTPluginTrackReaderFunction_GetTrackEditWithIndex)(MTPluginTrackReaderRef, CMItemCount, CMTimeMapping *);
typedef OSStatus (*MTPluginTrackReaderFunction_CreateCursorAtPresentationTimeStamp)(MTPluginTrackReaderRef, CMTime, MTPluginSampleCursorRef *);
typedef OSStatus (*MTPluginTrackReaderFunction_CreateCursorAtFirstSampleInDecodeOrder)(MTPluginTrackReaderRef, MTPluginSampleCursorRef *);
typedef OSStatus (*MTPluginTrackReaderFunction_CreateCursorAtLastSampleInDecodeOrder)(MTPluginTrackReaderRef, MTPluginSampleCursorRef *);

extern const CFStringRef kMTPluginFormatReader_SupportsPlayableHorizonQueries;
extern const CFStringRef kMTPluginFormatReaderProperty_Duration;
extern const CFStringRef kMTPluginFormatReaderProperty_Metadata;
extern const CFStringRef kMTPluginFormatReaderProperty_MetadataFormat;
extern const CFStringRef kMTPluginFormatReaderProperty_MetadataKeySpace;
extern const CFStringRef kMTPluginTrackReaderProperty_Dimensions;
extern const CFStringRef kMTPluginTrackReaderProperty_Enabled;
extern const CFStringRef kMTPluginTrackReaderProperty_EstimatedDataRate;
extern const CFStringRef kMTPluginTrackReaderProperty_FormatDescriptionArray;
extern const CFStringRef kMTPluginTrackReaderProperty_NaturalTimescale;
extern const CFStringRef kMTPluginTrackReaderProperty_NominalFrameRate;
extern const CFStringRef kMTPluginTrackReaderProperty_PreferredTransform;
extern const CFStringRef kMTPluginTrackReaderProperty_TotalSampleDataLength;
extern const CFStringRef kMTPluginTrackReaderProperty_UneditedDuration;

int64_t MTPluginByteSourceGetLength(MTPluginByteSourceRef);
OSStatus MTPluginByteSourceRead(MTPluginByteSourceRef, size_t, int64_t, void *, size_t *);
CFStringRef MTPluginByteSourceCopyFileName(MTPluginByteSourceRef);
void MTRegisterPluginFormatReaderBundleDirectory(CFURLRef directoryURL);

CMBaseClassID MTPluginFormatReaderGetClassID(void);
CMBaseClassID MTPluginSampleCursorGetClassID(void);
CMBaseClassID MTPluginTrackReaderGetClassID(void);

typedef struct {
    unsigned long version;
    MTPluginFormatReaderFunction_CopyTrackArray copyTrackArray;
    MTPluginFormatReaderFunction_ParseAdditionalFragments parseAdditionalFragments;
} MTPluginFormatReaderClass;

typedef struct {
    CMBaseVTable base;
    const MTPluginFormatReaderClass *pluginFormatReaderClass;
} MTPluginFormatReaderVTable;

typedef struct {
    unsigned long version;
    MTPluginSampleCursorFunction_Copy copy;
    MTPluginSampleCursorFunction_StepInDecodeOrderAndReportStepsTaken stepInDecodeOrderAndReportStepsTaken;
    MTPluginSampleCursorFunction_StepInPresentationOrderAndReportStepsTaken stepInPresentationOrderAndReportStepsTaken;
    MTPluginSampleCursorFunction_StepByDecodeTime stepByDecodeTime;
    MTPluginSampleCursorFunction_StepByPresentationTime stepByPresentationTime;
    MTPluginSampleCursorFunction_CompareInDecodeOrder compareInDecodeOrder;
    MTPluginSampleCursorFunction_GetSampleTiming getSampleTiming;
    MTPluginSampleCursorFunction_GetSyncInfo getSyncInfo;
    MTPluginSampleCursorFunction_GetDependencyInfo getDependencyInfo;
    MTPluginSampleCursorFunction_TestReorderingBoundary testReorderingBoundary;
    MTPluginSampleCursorFunction_CopySampleLocation copySampleLocation;
    MTPluginSampleCursorFunction_CopyChunkDetails copyChunkDetails;
    MTPluginSampleCursorFunction_CopyFormatDescription copyFormatDescription;
    MTPluginSampleCursorFunction_CreateSampleBuffer createSampleBuffer;
    MTPluginSampleCursorFunction_CopyUnrefinedSampleLocation copyUnrefinedSampleLocation;
    MTPluginSampleCursorFunction_RefineSampleLocation refineSampleLocation;
    MTPluginSampleCursorFunction_CopyExtendedSampleDependencyAttributes copyExtendedSampleDependencyAttributes;
    MTPluginSampleCursorFunction_GetPlayableHorizon getPlayableHorizon;
} MTPluginSampleCursorClass;

typedef struct {
    CMBaseVTable base;
    const MTPluginSampleCursorClass *pluginSampleCursorClass;
    const struct MTPluginSampleCursorReservedForOfficeUseOnly *reservedSetToNULL;
} MTPluginSampleCursorVTable;

typedef struct {
    unsigned long version;
    MTPluginTrackReaderFunction_GetTrackInfo getTrackInfo;
    MTPluginTrackReaderFunction_GetTrackEditCount getTrackEditCount;
    MTPluginTrackReaderFunction_GetTrackEditWithIndex getTrackEditWithIndex;
    MTPluginTrackReaderFunction_CreateCursorAtPresentationTimeStamp createCursorAtPresentationTimeStamp;
    MTPluginTrackReaderFunction_CreateCursorAtFirstSampleInDecodeOrder createCursorAtFirstSampleInDecodeOrder;
    MTPluginTrackReaderFunction_CreateCursorAtLastSampleInDecodeOrder createCursorAtLastSampleInDecodeOrder;
} MTPluginTrackReaderClass;

typedef struct {
    CMBaseVTable base;
    const MTPluginTrackReaderClass *pluginTrackReaderClass;
} MTPluginTrackReaderVTable;

#ifdef __cplusplus
}
#endif
