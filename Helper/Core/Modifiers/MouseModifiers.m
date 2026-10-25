//
// --------------------------------------------------------------------------
// MouseModifiers.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------

#import "MouseModifiers.h"
#import "Modifiers.h"
#import "Constants.h"
#import "SharedUtility.h"
#import "Logging.h"
#import "Threads.h"
#import "EventUtility.h"
#import "DeviceManager.h"
#import "ButtonInputReceiver.h"
#import "NSTimer+Additions.h"
#import "Mac_Mouse_Fix_Helper-Swift.h"

/// See MouseModifiers.h for the high-level idea.
///
/// Threading: Runs on `IOThread`, like the other input modules.
///
/// Why a dedicated tap instead of reusing `ButtonInputReceiver`?
///     `ButtonInputReceiver` deliberately ignores MB1 and MB2, and right-click has to be swallowed
///     before the context menu opens. MB3+ also need their click action deferred while they're a
///     scroll modifier, so this tap owns all configured buttons and replays a click on release if
///     the button wasn't actually used for scrolling.
///
/// Replays go in at `kCGSessionEventTap` and are therefore not seen by `ButtonInputReceiver`. That is
/// intentional: a button that is a mouse modifier is *not* also an action trigger. The Scrolling tab
/// says so (see `mouse-modifier-conflict-toast`), and it keeps a scroll from firing the button's
/// Click / Hold action as a side effect.

static CFMachPortRef _eventTap;
static BOOL _running = NO;
static BOOL _captureMode = NO;

/// Pending re-arm after the system disabled the tap. Re-enabling from inside the disable callback would
/// spin while secure input is active (the system immediately disables it again), so we retry later.
static NSTimer *_rearmTimer;

/// Buttons currently configured as scroll modifiers, pushed in from SwitchMaster.
static NSIndexSet *_configuredButtons;

/// Drag threshold (points) after which a held button is replayed as a real drag instead of
/// staying a candidate scroll modifier.
static const CGFloat _dragThreshold = 12.0;

/// Pending button state. Only one button can be pending at a time; a second press flushes the first.
/// The original clickState / timestamps / location are preserved so double- and triple-clicks survive.
static NSInteger _pendingButton = 0; /// MFMouseButtonNumber, 0 = none
static BOOL _pendingPassedThrough = NO;      /// Press was replayed for a drag
static BOOL _pendingUsedForModification = NO; /// A scroll modification actually fired
static int64_t _pendingClickState = 1;
static uint64_t _pendingDownTimestamp = 0;
static CGPoint _pendingDownLocation;

#pragma mark - Forward declarations

static CGEventRef _Nullable eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo);

@interface MouseModifiers ()
+ (void)scheduleRearm;
+ (void)cancelRearm;
@end

#pragma mark - Helpers

static void resetPendingState(void) {
    _pendingButton = 0;
    _pendingPassedThrough = NO;
    _pendingUsedForModification = NO;
    _pendingClickState = 1;
    _pendingDownTimestamp = 0;
    _pendingDownLocation = CGPointZero;
}

static void postClick(NSInteger button, CGPoint location, uint64_t downTimestamp, uint64_t upTimestamp, int64_t clickState) {
    
    if (downTimestamp == 0 || upTimestamp == 0) return;
    
    CGEventType downType = [SharedUtility CGEventTypeForButtonNumber:(MFMouseButtonNumber)button isMouseDown:YES];
    CGEventType upType   = [SharedUtility CGEventTypeForButtonNumber:(MFMouseButtonNumber)button isMouseDown:NO];
    CGMouseButton cgButton = [SharedUtility CGMouseButtonFromMFMouseButtonNumber:(MFMouseButtonNumber)button];
    
    CGEventRef down = CGEventCreateMouseEvent(NULL, downType, location, cgButton);
    CGEventRef up   = CGEventCreateMouseEvent(NULL, upType,   location, cgButton);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        return;
    }
    
    CGEventSetIntegerValueField(down, kCGMouseEventClickState, clickState);
    CGEventSetIntegerValueField(up,   kCGMouseEventClickState, clickState);
    CGEventSetTimestamp(down, downTimestamp);
    CGEventSetTimestamp(up,   upTimestamp);
    
    CGEventPost(kCGSessionEventTap, down);
    CGEventPost(kCGSessionEventTap, up);
    
    CFRelease(down);
    CFRelease(up);
}

static void postDragStart(NSInteger button, CGPoint location) {
    
    CGEventType downType = [SharedUtility CGEventTypeForButtonNumber:(MFMouseButtonNumber)button isMouseDown:YES];
    CGMouseButton cgButton = [SharedUtility CGMouseButtonFromMFMouseButtonNumber:(MFMouseButtonNumber)button];
    
    CGEventRef down = CGEventCreateMouseEvent(NULL, downType, location, cgButton);
    if (!down) return;
    CGEventSetIntegerValueField(down, kCGMouseEventClickState, 1);
    CGEventPost(kCGSessionEventTap, down);
    CFRelease(down);
}

@implementation MouseModifiers

#pragma mark - Load

+ (void)load_Manual {
    assertRunLoop(IOThread.runLoop);
    
    CGEventMask mask =
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDragged);
    
    _eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, eventTapCallback, NULL);
    if (!_eventTap) {
        DDLogError("MouseModifiers: CGEventTapCreate failed (missing accessibility permission?)");
        return;
    }
    
    CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
    CFRunLoopAddSource(IOThread.runLoop, runLoopSource, kCFRunLoopDefaultMode);
    CFRelease(runLoopSource);
    
    CGEventTapEnable(_eventTap, false);
}

#pragma mark - Interface

+ (void)setConfiguredButtons:(NSIndexSet *)buttons {
    assertRunLoop(IOThread.runLoop);
    _configuredButtons = [buttons copy];
}

+ (void)start {
    assertRunLoop(IOThread.runLoop);
    if (!_eventTap) return;
    if (_captureMode) return;
    
    /// `_running` is the state we *want*. The system can disable the tap behind our back
    /// (`kCGEventTapDisabledByUserInput`), in which case `_running` is still true but the tap is dead.
    /// Checking `CGEventTapIsEnabled` here lets the next SwitchMaster evaluation bring it back.
    if (_running && CGEventTapIsEnabled(_eventTap)) return;
    
    if (!_running) resetPendingState();
    _running = YES;
    CGEventTapEnable(_eventTap, true);
}

+ (void)stop {
    assertRunLoop(IOThread.runLoop);
    
    /// Guard against re-entrancy: `mouseModsChangedTo:` below triggers `SwitchMaster`, which calls
    /// `toggleMouseModTap()` and therefore `stop` again.
    if (!_running) return;
    
    _running = NO;
    
    /// If the tap stops while a button is still held (e.g. scroll kill switch toggled), replay the
    /// click so the button isn't "stuck", then clear the modifier state.
    if (_pendingButton != 0) {
        if (!_pendingUsedForModification && !_pendingPassedThrough) {
            postClick(_pendingButton, _pendingDownLocation, _pendingDownTimestamp, _pendingDownTimestamp, _pendingClickState);
        }
        resetPendingState();
        /// Defer the notification: `stop` is called from `SwitchMaster`'s togglers while it holds its
        /// state write lock, and `mouseModsChangedTo:` re-enters `SwitchMaster.modifiersChanged`.
        mfrun(IOThread.runLoop, ^{ [Modifiers mouseModsChangedTo:@(0)]; });
    }
    
    [self cancelRearm];
    
    if (_eventTap) CGEventTapEnable(_eventTap, false);
}

+ (BOOL)isRunning {
    return _running;
}

+ (void)setCaptureMode:(BOOL)enabled {
    assertRunLoop(IOThread.runLoop);
    
    _captureMode = enabled;
    if (!_eventTap) return;
    
    if (enabled) {
        [self cancelRearm];
        CGEventTapEnable(_eventTap, false);
        /// Let MB3+ clicks reach the main app while recording. Otherwise an already-assigned button
        /// would be consumed by `ButtonInputReceiver` and could never be captured again.
        [ButtonInputReceiver stop];
        return;
    }
    
    /// Recording finished. Clear any leftover state and let the SwitchMaster re-decide whether the
    /// tap should be running – `start` is a no-op while capturing, so `_running` may still be false.
    resetPendingState();
    [Modifiers mouseModsChangedTo:@(0)];
    [SwitchMaster.shared refreshMouseModifierTap];
}

+ (void)modificationHasBeenUsed {
    _pendingUsedForModification = YES;
}

/// Retry enabling the tap a moment later. Idempotent: only one retry is in flight at a time.
+ (void)scheduleRearm {
    assertRunLoop(IOThread.runLoop);
    
    if (_rearmTimer != nil) return;
    
    _rearmTimer = [NSTimer mf_scheduledTimerWithTimeInterval:0.5 mode:NSRunLoopCommonModes block:^(NSTimer *timer) {
        _rearmTimer = nil;
        [SwitchMaster.shared refreshMouseModifierTap];
    }];
}

+ (void)cancelRearm {
    assertRunLoop(IOThread.runLoop);
    [_rearmTimer invalidate];
    _rearmTimer = nil;
}

+ (NSNumber *)heldButton {
    /// `_pendingButton` is the physically-held configured button. It is cleared on release or when
    /// the tap stops, which is exactly when the modifier should disappear.
    return @(_pendingButton);
}

#pragma mark - Event tap

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    
    assertRunLoop(IOThread.runLoop);
    
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        
        if (type == kCGEventTapDisabledByTimeout) {
            if (_eventTap) CGEventTapEnable(_eventTap, true);
        } else {
            /// The system holds the tap off until something re-enables it, so the matching mouse-up will
            /// be lost. Drop the pending button, otherwise the modifier state (and the scroll axis) stays
            /// stuck forever.
            if (_pendingButton != 0) {
                resetPendingState();
                [Modifiers mouseModsChangedTo:@(0)];
            }
            /// Ask SwitchMaster to re-arm the tap once the disable condition (usually secure input) is
            /// gone. `start` re-checks `CGEventTapIsEnabled`, so this also recovers when the system
            /// disabled the tap without a pending button.
            [MouseModifiers scheduleRearm];
        }
        return event;
    }
    
    BOOL isDown = (type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown);
    BOOL isUp   = (type == kCGEventRightMouseUp   || type == kCGEventOtherMouseUp);
    BOOL isDrag = (type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged);
    
    /// MFMouseButtonNumber is 1-based, CGEvent field is 0-based.
    NSInteger button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) + 1;
    if (type == kCGEventRightMouseDown || type == kCGEventRightMouseUp || type == kCGEventRightMouseDragged) {
        button = kMFMouseButtonNumberRight;
    }
    
    /// Only buttons configured on the Scrolling tab are intercepted. Everything else passes through,
    /// so the regular button pipeline keeps owning MB3+ clicks that aren't mouse modifiers.
    if (![_configuredButtons containsIndex:button]) {
        return event;
    }
    
    /// Only take ownership of presses from mice that MMF manages. Trackpads, drawing tablets and other
    /// sources would otherwise lose their right-click to a swallow + replay round trip for nothing.
    /// Up/drag events don't need this check – they're already gated on `_pendingButton` below, and
    /// `CGEventGetSendingDevice()` is not reliable for dragged events.
    if (isDown) {
        /// Fall back to the old behavior when the sender can't be resolved, so a mouse whose events
        /// don't expose a device doesn't silently lose the feature.
        IOHIDDeviceRef sendingDevice = CGEventGetSendingDevice(event);
        if (sendingDevice != NULL && [DeviceManager attachedDeviceWithIOHIDDevice:sendingDevice] == nil) {
            return event;
        }
    }
    
    /// A different button arrived while another one is pending: resolve the pending one first.
    if (_pendingButton != 0 && _pendingButton != button) {
        if (!_pendingUsedForModification && !_pendingPassedThrough) {
            postClick(_pendingButton, _pendingDownLocation, _pendingDownTimestamp, _pendingDownTimestamp, _pendingClickState);
        }
        resetPendingState();
        [Modifiers mouseModsChangedTo:@(0)];
    }
    
    if (isDrag) {
        if (_pendingButton != button || _pendingPassedThrough) return event;
        
        CGPoint loc = CGEventGetLocation(event);
        CGFloat dx = loc.x - _pendingDownLocation.x;
        CGFloat dy = loc.y - _pendingDownLocation.y;
        
        if (sqrt(dx*dx + dy*dy) > _dragThreshold) {
            /// A drag started: replay the press at the current location and let the gesture through.
            /// Keep the button registered as a modifier: the user is still holding it, and dropping the
            /// modifier here used to make a following scroll tick fall back to vertical scrolling.
            postDragStart(button, loc);
            _pendingPassedThrough = YES;
        }
        return nil; /// Swallow until we know whether this is a scroll or a drag
    }
    
    if (isDown) {
        resetPendingState();
        _pendingButton = button;
        _pendingClickState = CGEventGetIntegerValueField(event, kCGMouseEventClickState);
        if (_pendingClickState <= 0) _pendingClickState = 1;
        _pendingDownTimestamp = CGEventGetTimestamp(event);
        _pendingDownLocation = CGEventGetLocation(event);
        
        [Modifiers mouseModsChangedTo:@(button)];
        return nil;
    }
    
    if (isUp) {
        if (_pendingButton != button) return event;
        
        if (_pendingPassedThrough) {
            /// Press was already replayed for a drag; let the release complete it.
            resetPendingState();
            [Modifiers mouseModsChangedTo:@(0)];
            return event;
        }
        
        if (!_pendingUsedForModification) {
            postClick(button, CGEventGetLocation(event), _pendingDownTimestamp, CGEventGetTimestamp(event), _pendingClickState);
        }
        
        resetPendingState();
        [Modifiers mouseModsChangedTo:@(0)];
        return nil;
    }
    
    return event;
}

@end
