/* Private CoreGraphics virtual-display API, declared by hand.
 *
 * There is no public route to a virtual display on macOS (README §6); every
 * shipping tool (BetterDisplay, DeskPad, FluffyDisplay, OpenDisplay) declares
 * these same interfaces. Shape verified against those projects; may break on
 * any macOS update (README §10).
 */
#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t serialNum;
@property(nonatomic, strong) void (^terminationHandler)
    (id sender, CGVirtualDisplay *display);
@end

@interface CGVirtualDisplayMode : NSObject
@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
@property(nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) uint32_t hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
