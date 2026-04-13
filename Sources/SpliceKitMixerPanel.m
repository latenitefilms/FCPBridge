//
//  SpliceKitMixerPanel.m
//  Audio mixer panel with per-clip volume faders inside FCP
//

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SpliceKit.h"

// Forward declarations from SpliceKitServer.m
extern id SpliceKit_getActiveTimelineModule(void);
extern id SpliceKit_storeHandle(id obj);
extern id SpliceKit_resolveHandle(NSString *handle);
extern double SpliceKit_channelValue(id channel);
extern BOOL SpliceKit_setChannelValue(id channel, double value);

// CMTime struct (matches FCP's internal layout)
typedef struct { long long value; int timescale; unsigned int flags; long long epoch; } SKMixer_CMTime;
typedef struct { SKMixer_CMTime start; SKMixer_CMTime duration; } SKMixer_CMTimeRange;

#if defined(__arm64__) || defined(__aarch64__)
  #define SK_STRET_MSG objc_msgSend
#else
  #define SK_STRET_MSG objc_msgSend_stret
#endif

#pragma mark - Fader State

@interface SpliceKitFaderState : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, strong) NSString *clipHandle;
@property (nonatomic, strong) NSString *volumeChannelHandle;
@property (nonatomic, strong) NSString *audioEffectStackHandle;
@property (nonatomic, strong) NSString *clipName;
@property (nonatomic, assign) NSInteger lane;
@property (nonatomic, assign) double volumeDB;
@property (nonatomic, assign) double volumeLinear;
@property (nonatomic, strong) NSString *role;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL isDragging;
@end

@implementation SpliceKitFaderState
@end

#pragma mark - Fader View

@interface SpliceKitFaderView : NSView
@property (nonatomic, strong) SpliceKitFaderState *state;
@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) NSTextField *dbLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *laneLabel;
@property (nonatomic, strong) NSTextField *indexLabel;
@property (nonatomic, copy) void (^onDragStart)(void);
@property (nonatomic, copy) void (^onDragChange)(double db);
@property (nonatomic, copy) void (^onDragEnd)(void);
- (void)updateFromState;
@end

// dB <-> slider position (0..100) with perceptual curve
static double dbToSliderPos(double db) {
    if (db <= -96) return 0;
    if (db >= 12) return 100;
    if (db >= 0) return 75.0 + (db / 12.0) * 25.0;
    double norm = (db + 96.0) / 96.0;
    return sqrt(norm) * 75.0;
}

static double sliderPosToDB(double pos) {
    if (pos <= 0) return -96;
    if (pos >= 100) return 12;
    if (pos >= 75) return ((pos - 75.0) / 25.0) * 12.0;
    double norm = pos / 75.0;
    return (norm * norm) * 96.0 - 96.0;
}

@implementation SpliceKitFaderView {
    BOOL _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame index:(NSInteger)idx {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 4;
        self.layer.borderColor = [NSColor.separatorColor CGColor];
        self.layer.borderWidth = 0.5;

        _state = [[SpliceKitFaderState alloc] init];
        _state.index = idx;

        // Index label at top
        _indexLabel = [self makeLabel:[NSString stringWithFormat:@"%ld", (long)idx + 1]
                                 size:11 bold:YES];
        _indexLabel.textColor = [NSColor secondaryLabelColor];

        // dB readout
        _dbLabel = [self makeLabel:@"--" size:10 bold:NO];
        _dbLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium];

        // Vertical slider
        _slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
        _slider.vertical = YES;
        _slider.minValue = 0;
        _slider.maxValue = 100;
        _slider.doubleValue = dbToSliderPos(0);
        _slider.target = self;
        _slider.action = @selector(sliderChanged:);
        _slider.continuous = YES;

        // Lane label
        _laneLabel = [self makeLabel:@"" size:9 bold:NO];
        _laneLabel.textColor = [NSColor tertiaryLabelColor];

        // Clip name
        _nameLabel = [self makeLabel:@"--" size:9 bold:NO];
        _nameLabel.maximumNumberOfLines = 2;
        _nameLabel.cell.truncatesLastVisibleLine = YES;
        _nameLabel.cell.lineBreakMode = NSLineBreakByTruncatingTail;

        for (NSView *v in @[_indexLabel, _dbLabel, _slider, _laneLabel, _nameLabel]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:v];
        }

        [NSLayoutConstraint activateConstraints:@[
            [_indexLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
            [_indexLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

            [_dbLabel.topAnchor constraintEqualToAnchor:_indexLabel.bottomAnchor constant:2],
            [_dbLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

            [_slider.topAnchor constraintEqualToAnchor:_dbLabel.bottomAnchor constant:4],
            [_slider.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_slider.bottomAnchor constraintEqualToAnchor:_laneLabel.topAnchor constant:-4],
            [_slider.widthAnchor constraintEqualToConstant:22],

            [_laneLabel.bottomAnchor constraintEqualToAnchor:_nameLabel.topAnchor constant:-2],
            [_laneLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

            [_nameLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
            [_nameLabel.heightAnchor constraintLessThanOrEqualToConstant:28],
        ]];
    }
    return self;
}

- (NSTextField *)makeLabel:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    label.alignment = NSTextAlignmentCenter;
    label.textColor = [NSColor labelColor];
    return label;
}

- (void)sliderChanged:(NSSlider *)sender {
    NSEvent *event = [NSApp currentEvent];
    BOOL starting = !_tracking;
    _tracking = YES;

    double db = sliderPosToDB(sender.doubleValue);
    _state.volumeDB = db;
    _state.isDragging = YES;
    [self updateDBLabel];

    if (starting && self.onDragStart) self.onDragStart();
    if (self.onDragChange) self.onDragChange(db);

    // Detect mouse-up (end of drag)
    if (event.type == NSEventTypeLeftMouseUp) {
        _tracking = NO;
        _state.isDragging = NO;
        if (self.onDragEnd) self.onDragEnd();
    }
}

- (void)updateFromState {
    BOOL active = _state.isActive;
    _slider.enabled = active;

    if (active && !_state.isDragging) {
        _slider.doubleValue = dbToSliderPos(_state.volumeDB);
    }

    [self updateDBLabel];
    _laneLabel.stringValue = active ? [NSString stringWithFormat:@"L%ld", (long)_state.lane] : @"";
    _nameLabel.stringValue = active ? (_state.clipName ?: @"") : @"--";
    _nameLabel.textColor = active ? [NSColor labelColor] : [NSColor tertiaryLabelColor];

    self.layer.backgroundColor = active
        ? [[NSColor controlBackgroundColor] colorWithAlphaComponent:0.3].CGColor
        : [NSColor clearColor].CGColor;
}

- (void)updateDBLabel {
    if (!_state.isActive) {
        _dbLabel.stringValue = @"--";
        _dbLabel.textColor = [NSColor tertiaryLabelColor];
        return;
    }
    if (_state.volumeDB <= -96) {
        _dbLabel.stringValue = @"-inf";
    } else {
        _dbLabel.stringValue = [NSString stringWithFormat:@"%.1f", _state.volumeDB];
    }
    _dbLabel.textColor = [NSColor labelColor];
}

@end

#pragma mark - Mixer Panel

@interface SpliceKitMixerPanel : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSMutableArray<SpliceKitFaderView *> *faderViews;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSView *statusDot;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL isPolling;
+ (instancetype)sharedPanel;
- (void)showPanel;
- (void)hidePanel;
- (BOOL)isVisible;
@end

@implementation SpliceKitMixerPanel

+ (instancetype)sharedPanel {
    static SpliceKitMixerPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[SpliceKitMixerPanel alloc] init]; });
    return instance;
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self showPanel]; });
        return;
    }
    [self setupPanelIfNeeded];
    [self.panel makeKeyAndOrderFront:nil];
    [self startPolling];
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        SpliceKit_executeOnMainThread(^{ [self hidePanel]; });
        return;
    }
    [self stopPolling];
    [self.panel orderOut:nil];
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

- (void)windowWillClose:(NSNotification *)notification {
    [self stopPolling];
}

#pragma mark - Panel Setup

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect frame = NSMakeRect(200, 200, 700, 380);
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow;

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:styleMask
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"Audio Mixer";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(500, 320);
    self.panel.delegate = self;
    self.panel.releasedWhenClosed = NO;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView *content = self.panel.contentView;
    content.wantsLayer = YES;

    [self buildUI:content];
}

- (void)buildUI:(NSView *)content {
    // --- Header bar ---
    NSView *header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.wantsLayer = YES;
    header.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];
    [content addSubview:header];

    // Status dot
    self.statusDot = [[NSView alloc] init];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius = 4;
    self.statusDot.layer.backgroundColor = [[NSColor systemGreenColor] CGColor];
    [header addSubview:self.statusDot];

    // Status label
    self.statusLabel = [NSTextField labelWithString:@"Connected"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    [header addSubview:self.statusLabel];

    // Title
    NSTextField *title = [NSTextField labelWithString:@"Audio Mixer"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont boldSystemFontOfSize:13];
    title.alignment = NSTextAlignmentCenter;
    [header addSubview:title];

    // --- Fader container ---
    NSStackView *faderStack = [[NSStackView alloc] init];
    faderStack.translatesAutoresizingMaskIntoConstraints = NO;
    faderStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    faderStack.distribution = NSStackViewDistributionFillEqually;
    faderStack.spacing = 1;
    [content addSubview:faderStack];

    // Create 10 faders
    self.faderViews = [NSMutableArray array];
    for (NSInteger i = 0; i < 10; i++) {
        SpliceKitFaderView *fv = [[SpliceKitFaderView alloc]
            initWithFrame:NSMakeRect(0, 0, 60, 300) index:i];

        __weak SpliceKitMixerPanel *weakSelf = self;
        NSInteger idx = i;
        fv.onDragStart = ^{
            [weakSelf beginVolumeChange:idx];
        };
        fv.onDragChange = ^(double db) {
            [weakSelf setVolume:idx db:db];
        };
        fv.onDragEnd = ^{
            [weakSelf endVolumeChange:idx];
        };

        [faderStack addArrangedSubview:fv];
        [self.faderViews addObject:fv];
    }

    // --- Layout ---
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:content.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:32],

        [self.statusDot.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:10],
        [self.statusDot.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.statusDot.widthAnchor constraintEqualToConstant:8],
        [self.statusDot.heightAnchor constraintEqualToConstant:8],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.statusDot.trailingAnchor constant:6],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [title.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [faderStack.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4],
        [faderStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:4],
        [faderStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-4],
        [faderStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-4],
    ]];
}

#pragma mark - Polling

- (void)startPolling {
    [self stopPolling];
    self.isPolling = YES;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                     target:self
                                                   selector:@selector(pollTimerFired:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)stopPolling {
    self.isPolling = NO;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)pollTimerFired:(NSTimer *)timer {
    if (!self.panel.isVisible) return;
    [self updateMixerState];
}

- (void)updateMixerState {
    @try {
        id timeline = SpliceKit_getActiveTimelineModule();
        if (!timeline) {
            self.statusLabel.stringValue = @"No timeline";
            self.statusDot.layer.backgroundColor = [[NSColor systemRedColor] CGColor];
            [self clearAllFaders];
            return;
        }

        self.statusLabel.stringValue = @"Connected";
        self.statusDot.layer.backgroundColor = [[NSColor systemGreenColor] CGColor];

        id sequence = nil;
        if ([timeline respondsToSelector:@selector(sequence)]) {
            sequence = ((id (*)(id, SEL))objc_msgSend)(timeline, @selector(sequence));
        }
        if (!sequence) { [self clearAllFaders]; return; }

        // Get playhead
        SKMixer_CMTime playhead = {0, 1, 0, 0};
        if ([timeline respondsToSelector:@selector(playheadTime)]) {
            playhead = ((SKMixer_CMTime (*)(id, SEL))SK_STRET_MSG)(timeline, @selector(playheadTime));
        }
        double playheadSec = (playhead.timescale > 0) ? (double)playhead.value / playhead.timescale : 0;

        // Get primaryObject / spine
        id primaryObj = nil;
        if ([sequence respondsToSelector:@selector(primaryObject)]) {
            primaryObj = ((id (*)(id, SEL))objc_msgSend)(sequence, @selector(primaryObject));
        }
        if (!primaryObj) { [self clearAllFaders]; return; }

        id spineItems = nil;
        if ([primaryObj respondsToSelector:@selector(containedItems)]) {
            spineItems = ((id (*)(id, SEL))objc_msgSend)(primaryObj, @selector(containedItems));
        }
        if (!spineItems || ![spineItems isKindOfClass:[NSArray class]]) { [self clearAllFaders]; return; }

        SEL erSel = NSSelectorFromString(@"effectiveRangeOfObject:");
        BOOL canGetRange = [primaryObj respondsToSelector:erSel];

        // Collect overlapping clips
        NSMutableArray<NSDictionary *> *clips = [NSMutableArray array];

        for (id item in (NSArray *)spineItems) {
            BOOL spineOverlaps = NO;
            double startSec = 0, endSec = 0;

            if (canGetRange) {
                @try {
                    SKMixer_CMTimeRange range = ((SKMixer_CMTimeRange (*)(id, SEL, id))SK_STRET_MSG)(
                        primaryObj, erSel, item);
                    startSec = (range.start.timescale > 0) ? (double)range.start.value / range.start.timescale : 0;
                    double dur = (range.duration.timescale > 0) ? (double)range.duration.value / range.duration.timescale : 0;
                    endSec = startSec + dur;
                    if (playheadSec >= startSec - 0.001 && playheadSec <= endSec + 0.001)
                        spineOverlaps = YES;
                } @catch (NSException *e) {}
            }

            if (spineOverlaps) {
                NSString *cls = NSStringFromClass([item class]);
                if (![cls containsString:@"Gap"] && ![cls containsString:@"Transition"]) {
                    NSDictionary *info = [self clipInfoForItem:item lane:0 start:startSec end:endSec];
                    if (info) [clips addObject:info];
                }
            }

            // Connected clips
            SEL anchoredSel = NSSelectorFromString(@"anchoredItems");
            if ([item respondsToSelector:anchoredSel]) {
                id anchored = ((id (*)(id, SEL))objc_msgSend)(item, anchoredSel);
                NSArray *arr = nil;
                if ([anchored isKindOfClass:[NSArray class]]) arr = (NSArray *)anchored;
                else if ([anchored isKindOfClass:[NSSet class]]) arr = [(NSSet *)anchored allObjects];

                for (id connected in arr ?: @[]) {
                    double cStart = 0, cEnd = 0;
                    BOOL connOverlaps = NO;
                    if (canGetRange) {
                        @try {
                            SKMixer_CMTimeRange range = ((SKMixer_CMTimeRange (*)(id, SEL, id))SK_STRET_MSG)(
                                primaryObj, erSel, connected);
                            cStart = (range.start.timescale > 0) ? (double)range.start.value / range.start.timescale : 0;
                            double dur = (range.duration.timescale > 0) ? (double)range.duration.value / range.duration.timescale : 0;
                            cEnd = cStart + dur;
                            if (playheadSec >= cStart - 0.001 && playheadSec <= cEnd + 0.001)
                                connOverlaps = YES;
                        } @catch (NSException *e) {}
                    }
                    if (!connOverlaps) continue;

                    NSString *cls = NSStringFromClass([connected class]);
                    if ([cls containsString:@"Transition"]) continue;

                    long long lane = 0;
                    if ([connected respondsToSelector:@selector(anchoredLane)])
                        lane = ((long long (*)(id, SEL))objc_msgSend)(connected, @selector(anchoredLane));

                    NSDictionary *info = [self clipInfoForItem:connected lane:(NSInteger)lane start:cStart end:cEnd];
                    if (info) [clips addObject:info];
                }
            }
        }

        // Sort by lane descending
        [clips sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSInteger lA = [a[@"lane"] integerValue], lB = [b[@"lane"] integerValue];
            if (lA != lB) return lB > lA ? NSOrderedAscending : NSOrderedDescending;
            return [a[@"name"] compare:b[@"name"] ?: @""];
        }];

        // Update fader views
        for (NSInteger i = 0; i < 10; i++) {
            SpliceKitFaderView *fv = self.faderViews[i];
            if (fv.state.isDragging) continue; // Don't update while dragging

            if (i < (NSInteger)clips.count) {
                NSDictionary *info = clips[i];
                fv.state.isActive = YES;
                fv.state.clipName = info[@"name"];
                fv.state.lane = [info[@"lane"] integerValue];
                fv.state.volumeDB = [info[@"volumeDB"] doubleValue];
                fv.state.volumeLinear = [info[@"volumeLinear"] doubleValue];
                fv.state.clipHandle = info[@"clipHandle"];
                fv.state.volumeChannelHandle = info[@"volumeChannelHandle"];
                fv.state.audioEffectStackHandle = info[@"audioEffectStackHandle"];
                fv.state.role = info[@"role"];
            } else {
                fv.state.isActive = NO;
                fv.state.clipName = nil;
                fv.state.clipHandle = nil;
                fv.state.volumeChannelHandle = nil;
                fv.state.audioEffectStackHandle = nil;
            }
            [fv updateFromState];
        }

    } @catch (NSException *e) {
        SpliceKit_log(@"[Mixer] Poll exception: %@", e.reason);
    }
}

- (NSDictionary *)clipInfoForItem:(id)item lane:(NSInteger)lane start:(double)start end:(double)end {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"lane"] = @(lane);
    info[@"start"] = @(start);
    info[@"end"] = @(end);
    info[@"clipHandle"] = SpliceKit_storeHandle(item);

    if ([item respondsToSelector:@selector(displayName)]) {
        id name = ((id (*)(id, SEL))objc_msgSend)(item, @selector(displayName));
        info[@"name"] = name ?: @"";
    }

    // Read volume via audioEffectsForIdentifier:
    @try {
        SEL aeSel = NSSelectorFromString(@"audioEffectsForIdentifier:");
        if ([item respondsToSelector:aeSel]) {
            id audioES = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(item, aeSel, 0ULL);
            if (audioES) {
                info[@"audioEffectStackHandle"] = SpliceKit_storeHandle(audioES);
                SEL volSel = NSSelectorFromString(@"audioLevelChannel");
                if ([audioES respondsToSelector:volSel]) {
                    id volChan = ((id (*)(id, SEL))objc_msgSend)(audioES, volSel);
                    if (volChan) {
                        double linear = SpliceKit_channelValue(volChan);
                        info[@"volumeLinear"] = @(linear);
                        info[@"volumeDB"] = (linear > 0) ? @(20.0 * log10(linear)) : @(-96.0);
                        info[@"volumeChannelHandle"] = SpliceKit_storeHandle(volChan);
                    }
                }
            }
        }
    } @catch (NSException *e) {}

    // Defaults if no audio
    if (!info[@"volumeDB"]) {
        info[@"volumeDB"] = @(0.0);
        info[@"volumeLinear"] = @(1.0);
    }

    return info;
}

- (void)clearAllFaders {
    for (SpliceKitFaderView *fv in self.faderViews) {
        fv.state.isActive = NO;
        fv.state.clipName = nil;
        fv.state.clipHandle = nil;
        fv.state.volumeChannelHandle = nil;
        [fv updateFromState];
    }
}

#pragma mark - Volume Control

- (void)beginVolumeChange:(NSInteger)faderIndex {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    NSString *esHandle = fv.state.audioEffectStackHandle;
    if (!esHandle) return;

    id effectStack = SpliceKit_resolveHandle(esHandle);
    if (!effectStack) return;

    @try {
        SEL beginSel = NSSelectorFromString(@"actionBegin:animationHint:deferUpdates:");
        if ([effectStack respondsToSelector:beginSel]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                effectStack, beginSel, @"Adjust Volume", nil, YES);
        }
    } @catch (NSException *e) {}
}

- (void)setVolume:(NSInteger)faderIndex db:(double)db {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    NSString *handle = fv.state.volumeChannelHandle;
    if (!handle) return;

    id channel = SpliceKit_resolveHandle(handle);
    if (!channel) return;

    double linear = (db <= -96.0) ? 0.0 : pow(10.0, db / 20.0);
    if (linear < 0.0) linear = 0.0;
    if (linear > 3.98) linear = 3.98;

    SpliceKit_setChannelValue(channel, linear);
}

- (void)endVolumeChange:(NSInteger)faderIndex {
    SpliceKitFaderView *fv = self.faderViews[faderIndex];
    NSString *esHandle = fv.state.audioEffectStackHandle;
    if (!esHandle) return;

    id effectStack = SpliceKit_resolveHandle(esHandle);
    if (!effectStack) return;

    @try {
        SEL endSel = NSSelectorFromString(@"actionEnd:save:error:");
        if ([effectStack respondsToSelector:endSel]) {
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
                effectStack, endSel, @"Adjust Volume", YES, nil);
        }
    } @catch (NSException *e) {}

    fv.state.isDragging = NO;
}

@end
