//
// --------------------------------------------------------------------------
// MouseModifiers.h
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Mouse-button equivalents of the keyboard modifiers on the Scrolling tab.
///
/// The active button is published into `Modifiers` under `kMFModificationPreconditionKeyMouseButtons`
/// so the regular remap pipeline can treat it like any other modification precondition.
///
/// While a configured button is held, its events are swallowed so they don't reach the system.
/// If the button is released without having modified anything, a click is replayed with the
/// original clickState/timestamp so double- and triple-clicks keep working.
@interface MouseModifiers : NSObject

+ (void)load_Manual;

/// The buttons that are currently configured as scroll modifiers (MFMouseButtonNumber values).
+ (void)setConfiguredButtons:(NSIndexSet *)buttons;

+ (void)start;
+ (void)stop;
+ (BOOL)isRunning;

/// While the user is recording a button in the Scrolling tab, the tap must let the clicks through,
/// otherwise a button that is already a modifier could never be captured again.
+ (void)setCaptureMode:(BOOL)enabled;

/// The configured button that is currently held down, or `0` when none.
/// Used by `Modifiers` to keep the published modifier state in sync while the button is held.
+ (NSNumber *)heldButton;

/// Called from `Modifiers.handleModificationHasBeenUsed`.
/// Marks the currently held mouse modifier as consumed so its release doesn't replay a click.
+ (void)modificationHasBeenUsed;

@end

NS_ASSUME_NONNULL_END
