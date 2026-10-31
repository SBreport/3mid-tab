#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <math.h>

@interface PermissionManager : NSObject
+ (BOOL)isAccessibilityTrusted;
+ (void)requestAccessibilityIfNeeded;
@end

@implementation PermissionManager
+ (BOOL)isAccessibilityTrusted {
    return AXIsProcessTrusted();
}

+ (void)requestAccessibilityIfNeeded {
    if ([self isAccessibilityTrusted]) {
        return;
    }

    NSDictionary *options = @{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES
    };
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}
@end

@interface MiddleClickEmitter : NSObject
- (void)middleClick;
- (void)middleClickAt:(CGPoint)location;
@end

@implementation MiddleClickEmitter
- (void)middleClick {
    CGEventRef current = CGEventCreate(NULL);
    CGPoint location = current ? CGEventGetLocation(current) : CGPointZero;
    if (current) {
        CFRelease(current);
    }

    [self middleClickAt:location];
}

- (void)middleClickAt:(CGPoint)location {
    [self postType:kCGEventOtherMouseDown at:location];
    usleep(12000);
    [self postType:kCGEventOtherMouseUp at:location];
}

- (void)postType:(CGEventType)type at:(CGPoint)location {
    CGEventRef event = CGEventCreateMouseEvent(
        NULL,
        type,
        location,
        kCGMouseButtonCenter
    );

    if (!event) {
        return;
    }

    CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 2);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
}
@end

@interface MiddleButtonAutoScroller : NSObject
- (BOOL)start;
- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type;
- (void)recoverEventTap;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@end

static CGEventRef AutoScrollEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);

@implementation MiddleButtonAutoScroller {
    CFMachPortRef _eventTap;
    CFRunLoopSourceRef _runLoopSource;
    BOOL _middleButtonDown;
    BOOL _moved;
    CGPoint _lastLocation;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = NO;
    }
    return self;
}

- (BOOL)start {
    CGEventMask mask = CGEventMaskBit(kCGEventOtherMouseDown) |
                       CGEventMaskBit(kCGEventOtherMouseUp) |
                       CGEventMaskBit(kCGEventOtherMouseDragged) |
                       CGEventMaskBit(kCGEventMouseMoved);
    _eventTap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        AutoScrollEventTapCallback,
        (__bridge void *)self
    );
    if (!_eventTap) {
        return NO;
    }

    _runLoopSource = CFMachPortCreateRunLoopSource(NULL, _eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _runLoopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_eventTap, true);
    return YES;
}

- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type {
    if (!self.enabled) {
        return event;
    }

    if (_middleButtonDown && type != kCGEventOtherMouseUp &&
        !CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonCenter)) {
        _middleButtonDown = NO;
        _moved = NO;
    }

    if (type == kCGEventOtherMouseDown &&
        CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) == kCGMouseButtonCenter) {
        _middleButtonDown = YES;
        _moved = NO;
        _lastLocation = CGEventGetLocation(event);
        return event;
    }

    if (type == kCGEventOtherMouseUp &&
        CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) == kCGMouseButtonCenter &&
        _middleButtonDown) {
        _middleButtonDown = NO;
        return _moved ? NULL : event;
    }

    if (_middleButtonDown &&
        (type == kCGEventMouseMoved || type == kCGEventOtherMouseDragged)) {
        CGPoint location = CGEventGetLocation(event);
        CGFloat dx = location.x - _lastLocation.x;
        CGFloat dy = location.y - _lastLocation.y;
        _lastLocation = location;

        if (fabs(dx) < 0.5 && fabs(dy) < 0.5) {
            return NULL;
        }

        _moved = YES;
        int32_t vertical = (int32_t)llround(-dy);
        int32_t horizontal = (int32_t)llround(dx);
        if (vertical != 0 || horizontal != 0) {
            CGEventRef scroll = CGEventCreateScrollWheelEvent(
                NULL,
                kCGScrollEventUnitPixel,
                2,
                vertical,
                horizontal
            );
            if (scroll) {
                CGEventPost(kCGHIDEventTap, scroll);
                CFRelease(scroll);
            }
        }
        return event;
    }

    return event;
}

- (void)recoverEventTap {
    _middleButtonDown = NO;
    _moved = NO;
    if (_eventTap && !CGEventTapIsEnabled(_eventTap)) {
        CGEventTapEnable(_eventTap, true);
    }
}

- (void)dealloc {
    if (_eventTap) {
        CGEventTapEnable(_eventTap, false);
    }
    if (_runLoopSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _runLoopSource, kCFRunLoopCommonModes);
        CFRelease(_runLoopSource);
    }
    if (_eventTap) {
        CFRelease(_eventTap);
    }
}
@end

static CGEventRef AutoScrollEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    MiddleButtonAutoScroller *scroller = (__bridge MiddleButtonAutoScroller *)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [scroller recoverEventTap];
        return event;
    }
    return [scroller handleEvent:event type:type];
}

@interface ThreeFingerTapRecognizer : NSObject
- (BOOL)handleTouches:(NSSet<NSTouch *> *)touches;
- (void)cancel;
@end

@implementation ThreeFingerTapRecognizer {
    NSDate *_startedAt;
    NSMutableDictionary<id<NSCopying>, NSValue *> *_startPositions;
    BOOL _exceededMovement;
    BOOL _sawThreeFingers;
}

static const NSUInteger RequiredFingerCount = 3;
static const NSTimeInterval MaxDuration = 0.80;
static const CGFloat MaxMovement = 0.08;

- (instancetype)init {
    self = [super init];
    if (self) {
        _startPositions = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)handleTouches:(NSSet<NSTouch *> *)touches {
    NSMutableArray<NSTouch *> *activeTouches = [NSMutableArray array];
    NSMutableArray<NSTouch *> *endedTouches = [NSMutableArray array];

    for (NSTouch *touch in touches) {
        if (touch.phase == NSTouchPhaseEnded || touch.phase == NSTouchPhaseCancelled) {
            [endedTouches addObject:touch];
        } else {
            [activeTouches addObject:touch];
        }
    }

    if (activeTouches.count == RequiredFingerCount && _startedAt == nil) {
        _startedAt = [NSDate date];
        [_startPositions removeAllObjects];
        _sawThreeFingers = YES;

        for (NSTouch *touch in activeTouches) {
            _startPositions[touch.identity] = [NSValue valueWithPoint:touch.normalizedPosition];
        }

        _exceededMovement = NO;
        return NO;
    }

    if (_startedAt != nil) {
        for (NSTouch *touch in activeTouches) {
            NSValue *startValue = _startPositions[touch.identity];
            if (!startValue) {
                continue;
            }

            NSPoint start = startValue.pointValue;
            NSPoint current = touch.normalizedPosition;
            CGFloat dx = start.x - current.x;
            CGFloat dy = start.y - current.y;
            CGFloat distance = sqrt(dx * dx + dy * dy);

            if (distance > MaxMovement) {
                _exceededMovement = YES;
            }
        }
    }

    if (_startedAt != nil && _sawThreeFingers && activeTouches.count < RequiredFingerCount && endedTouches.count > 0) {
        NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:_startedAt];
        BOOL recognized = duration <= MaxDuration && !_exceededMovement;
        [self cancel];
        return recognized;
    }

    if (activeTouches.count > RequiredFingerCount) {
        [self cancel];
    }

    return NO;
}

- (void)cancel {
    _startedAt = nil;
    [_startPositions removeAllObjects];
    _exceededMovement = NO;
    _sawThreeFingers = NO;
}
@end

@interface TouchPadView : NSView
@property (nonatomic, assign) BOOL enabled;
- (void)sendMiddleClick;
@end

@implementation TouchPadView {
    ThreeFingerTapRecognizer *_recognizer;
    MiddleClickEmitter *_emitter;
    NSTextField *_statusLabel;
    NSTextField *_permissionLabel;
    NSTextField *_eventLabel;
    NSTextField *_clickCountLabel;
    NSUInteger _clickCount;
    NSDate *_lastClickAt;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _enabled = YES;
        _recognizer = [[ThreeFingerTapRecognizer alloc] init];
        _emitter = [[MiddleClickEmitter alloc] init];

        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
        self.allowedTouchTypes = NSTouchTypeMaskIndirect;
        self.wantsRestingTouches = NO;

        [self setupLabels];
    }
    return self;
}

- (void)setupLabels {
    NSTextField *titleLabel = [NSTextField labelWithString:@"3mid-tab"];
    NSTextField *hintLabel = [NSTextField labelWithString:@"Tap this window with three fingers to send a middle click."];
    _statusLabel = [NSTextField labelWithString:@"Enabled"];
    _permissionLabel = [NSTextField labelWithString:@""];
    _eventLabel = [NSTextField labelWithString:@"Waiting for touch input..."];
    _clickCountLabel = [NSTextField labelWithString:@"Middle clicks sent: 0"];
    NSButton *testButton = [NSButton buttonWithTitle:@"Send test middle click"
                                              target:self
                                              action:@selector(sendMiddleClick)];

    NSArray<NSTextField *> *labels = @[titleLabel, hintLabel, _statusLabel, _permissionLabel, _eventLabel, _clickCountLabel];
    for (NSTextField *label in labels) {
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:label];
    }
    testButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:testButton];

    titleLabel.font = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
    hintLabel.font = [NSFont systemFontOfSize:14];
    hintLabel.textColor = NSColor.secondaryLabelColor;
    _statusLabel.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _statusLabel.textColor = NSColor.systemGreenColor;
    _permissionLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    _eventLabel.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    _eventLabel.textColor = NSColor.secondaryLabelColor;
    _clickCountLabel.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _clickCountLabel.textColor = NSColor.labelColor;

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:42],
        [hintLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [hintLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:14],
        [_statusLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_statusLabel.topAnchor constraintEqualToAnchor:hintLabel.bottomAnchor constant:22],
        [_permissionLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_permissionLabel.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:10],
        [_eventLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_eventLabel.topAnchor constraintEqualToAnchor:_permissionLabel.bottomAnchor constant:12],
        [_clickCountLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_clickCountLabel.topAnchor constraintEqualToAnchor:_eventLabel.bottomAnchor constant:14],
        [testButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [testButton.topAnchor constraintEqualToAnchor:_clickCountLabel.bottomAnchor constant:18]
    ]];

    [self refreshPermissionLabel];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    _statusLabel.stringValue = enabled ? @"Enabled" : @"Disabled";
    _statusLabel.textColor = enabled ? NSColor.systemGreenColor : NSColor.systemRedColor;
}

- (void)touchesBeganWithEvent:(NSEvent *)event {
    [self handleEvent:event phaseName:@"began"];
}

- (void)touchesMovedWithEvent:(NSEvent *)event {
    [self handleEvent:event phaseName:@"moved"];
}

- (void)touchesEndedWithEvent:(NSEvent *)event {
    [self handleEvent:event phaseName:@"ended"];
}

- (void)touchesCancelledWithEvent:(NSEvent *)event {
    [_recognizer cancel];
    _eventLabel.stringValue = @"Touch cancelled";
}

- (void)handleEvent:(NSEvent *)event phaseName:(NSString *)phaseName {
    if (!self.enabled) {
        return;
    }

    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:self];
    _eventLabel.stringValue = [NSString stringWithFormat:@"%@: %lu touch(es)", phaseName, touches.count];

    if ([_recognizer handleTouches:touches]) {
        [self sendMiddleClick];
    }
}

- (void)sendMiddleClick {
    if (_lastClickAt && [[NSDate date] timeIntervalSinceDate:_lastClickAt] < 0.20) {
        return;
    }

    _lastClickAt = [NSDate date];
    [self refreshPermissionLabel];
    [_emitter middleClick];
    _clickCount += 1;
    _eventLabel.stringValue = @"Middle click sent";
    _eventLabel.textColor = NSColor.systemGreenColor;
    _clickCountLabel.stringValue = [NSString stringWithFormat:@"Middle clicks sent: %lu", _clickCount];
}

- (void)refreshPermissionLabel {
    BOOL trusted = [PermissionManager isAccessibilityTrusted];
    _permissionLabel.stringValue = trusted ? @"Accessibility: allowed" : @"Accessibility: not allowed";
    _permissionLabel.textColor = trusted ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}
@end

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef device, void *touches, int touchCount, double timestamp, int frame);
typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(MTDeviceRef device, MTContactCallback callback);
typedef void (*MTDeviceStartFn)(MTDeviceRef device, int options);
typedef void (*MTDeviceStopFn)(MTDeviceRef device);

@interface GlobalMultitouchMonitor : NSObject
- (instancetype)initWithTapHandler:(dispatch_block_t)tapHandler;
- (BOOL)start;
- (BOOL)restart;
- (void)recordFrame;
@end

static GlobalMultitouchMonitor *ActiveGlobalMonitor;

@implementation GlobalMultitouchMonitor {
    dispatch_block_t _tapHandler;
    void *_framework;
    CFArrayRef _devices;
    MTDeviceCreateListFn _createList;
    MTRegisterContactFrameCallbackFn _registerCallback;
    MTDeviceStartFn _startDevice;
    MTDeviceStopFn _stopDevice;
    NSDate *_startedAt;
    MTDeviceRef _activeDevice;
    NSTimer *_watchdogTimer;
    CFAbsoluteTime _lastFrameAt;
}

static const NSTimeInterval GlobalTapMaxDuration = 0.80;
static const NSTimeInterval GlobalMonitorWatchdogInterval = 2.0;
static const NSTimeInterval GlobalMonitorStaleAfter = 6.0;

static int GlobalMultitouchCallback(MTDeviceRef device, void *touches, int touchCount, double timestamp, int frame) {
    GlobalMultitouchMonitor *monitor = ActiveGlobalMonitor;
    [monitor recordFrame];
    [monitor handleDevice:device touchCount:touchCount];
    return 0;
}

- (instancetype)initWithTapHandler:(dispatch_block_t)tapHandler {
    self = [super init];
    if (self) {
        _tapHandler = [tapHandler copy];
    }
    return self;
}

- (BOOL)start {
    _framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!_framework) {
        return NO;
    }

    _createList = (MTDeviceCreateListFn)dlsym(_framework, "MTDeviceCreateList");
    _registerCallback = (MTRegisterContactFrameCallbackFn)dlsym(_framework, "MTRegisterContactFrameCallback");
    _startDevice = (MTDeviceStartFn)dlsym(_framework, "MTDeviceStart");
    _stopDevice = (MTDeviceStopFn)dlsym(_framework, "MTDeviceStop");

    if (!_createList || !_registerCallback || !_startDevice || !_stopDevice) {
        return NO;
    }

    ActiveGlobalMonitor = self;
    BOOL started = [self restart];
    __weak GlobalMultitouchMonitor *weakSelf = self;
    _watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:GlobalMonitorWatchdogInterval
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        GlobalMultitouchMonitor *strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }

        CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - strongSelf->_lastFrameAt;
        if (elapsed > GlobalMonitorStaleAfter) {
            [strongSelf restart];
        }
    }];
    return started;
}

- (BOOL)restart {
    _startedAt = nil;
    _activeDevice = NULL;
    _lastFrameAt = CFAbsoluteTimeGetCurrent();

    if (_devices && _stopDevice) {
        CFIndex oldCount = CFArrayGetCount(_devices);
        for (CFIndex i = 0; i < oldCount; i++) {
            _stopDevice((MTDeviceRef)CFArrayGetValueAtIndex(_devices, i));
        }
        CFRelease(_devices);
        _devices = NULL;
    }

    _devices = _createList ? _createList() : NULL;
    if (!_devices) {
        return NO;
    }

    CFIndex count = CFArrayGetCount(_devices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(_devices, i);
        _registerCallback(device, GlobalMultitouchCallback);
        _startDevice(device, 0);
    }

    return count > 0;
}

- (void)recordFrame {
    _lastFrameAt = CFAbsoluteTimeGetCurrent();
}

- (void)handleDevice:(MTDeviceRef)device touchCount:(int)touchCount {
    if (touchCount == 3 && !_startedAt) {
        _startedAt = [NSDate date];
        _activeDevice = device;
        return;
    }

    if (!_startedAt || _activeDevice != device) {
        return;
    }

    NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:_startedAt];
    if (duration > GlobalTapMaxDuration) {
        _startedAt = nil;
        _activeDevice = NULL;
        return;
    }

    if (touchCount < 3) {
        _startedAt = nil;
        _activeDevice = NULL;
        if (_tapHandler) {
            dispatch_async(dispatch_get_main_queue(), _tapHandler);
        }
    }
}

- (void)dealloc {
    [_watchdogTimer invalidate];
    if (_devices && _stopDevice) {
        CFIndex count = CFArrayGetCount(_devices);
        for (CFIndex i = 0; i < count; i++) {
            _stopDevice((MTDeviceRef)CFArrayGetValueAtIndex(_devices, i));
        }
    }
    if (_devices) {
        CFRelease(_devices);
    }
    if (_framework) {
        dlclose(_framework);
    }
    if (ActiveGlobalMonitor == self) {
        ActiveGlobalMonitor = nil;
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    NSStatusItem *_statusItem;
    NSWindow *_window;
    TouchPadView *_touchView;
    GlobalMultitouchMonitor *_globalMonitor;
    MiddleButtonAutoScroller *_autoScroller;
    NSMenuItem *_autoScrollMenuItem;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self setupStatusItem];
    [self setupWindow];
    [self setupGlobalMonitor];
    [self setupAutoScroller];
    [PermissionManager requestAccessibilityIfNeeded];
}

- (void)setupStatusItem {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *menuIcon = [NSImage imageNamed:@"MenuIcon"];
    menuIcon.template = YES;
    _statusItem.button.image = menuIcon;
    _statusItem.button.toolTip = @"3mid-tab";

    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Show Touch Pad" action:@selector(showWindow) keyEquivalent:@"s"];
    [menu addItemWithTitle:@"Toggle Enabled" action:@selector(toggleEnabled) keyEquivalent:@"e"];
    _autoScrollMenuItem = [menu addItemWithTitle:@"Mouse Auto Scroll (Middle + Move)" action:@selector(toggleAutoScroll:) keyEquivalent:@""];
    _autoScrollMenuItem.state = NSControlStateValueOff;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Restart 3mid-tab" action:@selector(restart) keyEquivalent:@"r"];
    [menu addItemWithTitle:@"Quit" action:@selector(quit) keyEquivalent:@"q"];
    _statusItem.menu = menu;
}

- (void)setupWindow {
    NSRect frame = NSMakeRect(0, 0, 420, 320);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    _window.title = @"3mid-tab";
    [_window center];

    _touchView = [[TouchPadView alloc] initWithFrame:frame];
    _window.contentView = _touchView;
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)setupGlobalMonitor {
    __weak AppDelegate *weakSelf = self;
    _globalMonitor = [[GlobalMultitouchMonitor alloc] initWithTapHandler:^{
        AppDelegate *strongSelf = weakSelf;
        if (strongSelf->_touchView.enabled) {
            [strongSelf->_touchView sendMiddleClick];
        }
    }];

    [_globalMonitor start];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenParametersChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenParametersChanged:)
                                                 name:NSWorkspaceDidWakeNotification
                                               object:NSWorkspace.sharedWorkspace];
}

- (void)screenParametersChanged:(NSNotification *)notification {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self->_globalMonitor restart];
    });
}

- (void)setupAutoScroller {
    _autoScroller = [[MiddleButtonAutoScroller alloc] init];
    [_autoScroller start];
}

- (void)showWindow {
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)toggleEnabled {
    _touchView.enabled = !_touchView.enabled;
}

- (void)toggleAutoScroll:(NSMenuItem *)sender {
    _autoScroller.enabled = !_autoScroller.isEnabled;
    sender.state = _autoScroller.isEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)quit {
    [NSApp terminate:nil];
}

- (void)restart {
    NSString *appPath = NSBundle.mainBundle.bundlePath;
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-c", @"sleep 0.3; exec /usr/bin/open \"$1\"", @"3mid-tab-restart", appPath];
    [task launch];
    [NSApp terminate:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }

    return 0;
}
