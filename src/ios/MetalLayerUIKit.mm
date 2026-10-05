// UIKit implementation of CreateMetalLayer() (Renderer/Metal/MetalLayer.h).
// The macOS version (Renderer/Metal/MetalLayer.mm) does the same with an NSView child view.

#include "Cafe/HW/Latte/Renderer/Metal/MetalLayer.h"
#include "WiiPadLog.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>

@interface WiiPadMetalView : UIView
@end

@implementation WiiPadMetalView
+ (Class)layerClass
{
	return [CAMetalLayer class];
}
@end

// handle: the UIView* stored in WindowSystem::WindowInfo::window_main/window_pad.surface.
// Must be called on the main thread (UIKit).
void* CreateMetalLayer(void* handle, float& scaleX, float& scaleY)
{
	if (![NSThread isMainThread])
		WiiPadLog::Fatal("CreateMetalLayer called off the main thread (UIKit requires the main thread)");

	UIView* parent = (__bridge UIView*)handle;
	CGFloat scale = parent.traitCollection.displayScale;
	if (scale <= 0.0)
		scale = 2.0; // view not yet in a window; every supported iPad is 2x

	WiiPadMetalView* view = [[WiiPadMetalView alloc] initWithFrame:parent.bounds];
	view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	view.contentScaleFactor = scale;
	view.userInteractionEnabled = NO;
	view.layer.contentsScale = scale;
	[parent addSubview:view];

	scaleX = (float)scale;
	scaleY = (float)scale;

	WiiPadLog::Write(fmt::format("CreateMetalLayer: CAMetalLayer {}x{} pt, scale {}",
		(int)parent.bounds.size.width, (int)parent.bounds.size.height, (double)scale));

	// +1 reference, balanced by MetalLayerHandle's release(); the view keeps the layer alive while attached.
	return (__bridge_retained void*)view.layer;
}
