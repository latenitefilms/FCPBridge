#pragma once

#include <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    kCMBaseObject_ClassVersion_1 = 1,
    kCMBaseObject_ClassVersion_2 = 2,
    kCMBaseObject_ClassVersion_3 = 3,
};

enum {
    kCMBaseObjectError_ValueNotAvailable = -12783,
};

typedef struct OpaqueCMBaseObject *CMBaseObjectRef;
typedef struct OpaqueCMBaseClass *CMBaseClassID;
typedef struct OpaqueCMBaseProtocol *CMBaseProtocolID;

typedef OSStatus (*CMBaseObjectCopyPropertyFunction)(CMBaseObjectRef, CFStringRef, CFAllocatorRef, void *);
typedef OSStatus (*CMBaseObjectSetPropertyFunction)(CMBaseObjectRef, CFStringRef, CFTypeRef);

typedef struct {
    CMBaseClassVersion version;
    CFStringRef (*copyProtocolDebugDescription)(CMBaseObjectRef);
} CMBaseProtocol;

struct CMBaseProtocolVTable {
    const struct OpaqueCMBaseProtocolVTableReserved *reserved;
    const CMBaseProtocol *baseProtocol;
};

typedef struct CMBaseProtocolTableEntry {
    CMBaseProtocolID (*getProtocolID)(void);
    struct CMBaseProtocolVTable *protocolVTable;
} CMBaseProtocolTableEntry;

struct CMBaseProtocolTable {
    uint32_t version;
    uint32_t numSupportedProtocols;
    CMBaseProtocolTableEntry *supportedProtocols;
};

#pragma pack(push, 4)
typedef struct {
    CMBaseClassVersion version;
    size_t derivedStorageSize;
    Boolean (*equal)(CMBaseObjectRef, CMBaseObjectRef);
    OSStatus (*invalidate)(CMBaseObjectRef);
    void (*finalize)(CMBaseObjectRef);
    CFStringRef (*copyDebugDescription)(CMBaseObjectRef);
    CMBaseObjectCopyPropertyFunction copyProperty;
    CMBaseObjectSetPropertyFunction setProperty;
    OSStatus (*notificationBarrier)(CMBaseObjectRef);
    const struct CMBaseProtocolTable *protocolTable;
} CMBaseClass;
#pragma pack(pop)

typedef struct {
    const struct OpaqueCMBaseVTableReserved *reserved;
    const CMBaseClass *baseClass;
} CMBaseVTable;

OSStatus CMDerivedObjectCreate(CFAllocatorRef, const CMBaseVTable *, CMBaseClassID, CMBaseObjectRef *);
void *CMBaseObjectGetDerivedStorage(CMBaseObjectRef);
const CMBaseVTable *CMBaseObjectGetVTable(CMBaseObjectRef);

#ifdef __cplusplus
}
#endif
