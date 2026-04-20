//
//  SpliceKitTimelinePerfMode.m
//  Master Performance Mode toggle for A/B testing timeline speed changes.
//
//  Flipping this one switch enables/disables all three timeline performance
//  features in a known-consistent combination:
//
//    - Timeline interaction suspend (filmstrip + anchored-clip layer updates
//      frozen during pinch / marquee / scrollbar drag)
//    - 120Hz cosmetic playhead overlay (smooth line during playback)
//    - TLKOptimizedReload (Apple's hidden fast reload path)
//
//  Individual sub-toggles remain available via bridge options for fine-grained
//  A/B. The master toggle's value is authoritative — when ON, all sub-toggles
//  are forced ON; when OFF, all sub-toggles are forced OFF.
//

#import "SpliceKit.h"
#import <Foundation/Foundation.h>

static NSString * const kDefTimelinePerfMode = @"SpliceKitTimelinePerformanceMode";

BOOL SpliceKit_isTimelinePerformanceModeEnabled(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kDefTimelinePerfMode];
    // Default ON: fresh installs get Smooth Scroll turned on in the Splices
    // menu. Users who turned it off explicitly have a saved NSNumber here
    // which we respect.
    return n ? [n boolValue] : YES;
}

void SpliceKit_setTimelinePerformanceModeEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kDefTimelinePerfMode];

    // Apply to each sub-feature. Keeping sub-toggles individually settable
    // afterwards is intentional — someone can narrow down which one regressed
    // by flipping one off without killing the whole experiment.
    SpliceKit_setTimelineInteractionSuspendEnabled(enabled);
    SpliceKit_setTimelinePlayheadOverlayEnabled(enabled);
    SpliceKit_setTLKOptimizedReloadEnabled(enabled);

    SpliceKit_log(@"[PerfMode] Timeline Performance Mode %@", enabled ? @"ON" : @"OFF");
}

// Called from appDidLaunch. Applies whatever the user last set — defaulting
// to ON for fresh installs so Smooth Scroll is active out of the box. Users
// can still toggle it off from the Splices menu or via the bridge option.
void SpliceKit_installTimelinePerformanceMode(void) {
    BOOL enabled = SpliceKit_isTimelinePerformanceModeEnabled();
    if (!enabled) {
        // Still allow individual sub-features to install themselves from their
        // own saved defaults — don't force-disable here. That lets someone
        // test a single sub-feature in isolation without flipping perf mode on.
        if (SpliceKit_isTimelineInteractionSuspendEnabled())
            SpliceKit_installTimelineInteractionSuspend();
        if (SpliceKit_isTimelinePlayheadOverlayEnabled())
            SpliceKit_installTimelinePlayheadOverlay();
        if (SpliceKit_isTLKOptimizedReloadEnabled())
            SpliceKit_setTLKOptimizedReloadEnabled(YES);
        return;
    }
    // Master ON → force all sub-features on.
    SpliceKit_setTimelinePerformanceModeEnabled(YES);
}
