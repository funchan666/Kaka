#import <React/RCTViewComponentView.h>
#import <React-RCTAppDelegate/RCTDefaultReactNativeFactoryDelegate.h>
#import <WebKit/WebKit.h>
#import <react/renderer/components/KakaSpec/ComponentDescriptors.h>
#import <react/renderer/components/KakaSpec/RCTComponentViewHelpers.h>
#import <react/renderer/components/KakaSpec/ShadowNodes.h>

#import "Kaka-Swift.h"

using namespace facebook::react;

@interface KakaSurfaceComponentView : RCTViewComponentView <RCTKakaSurfaceViewProtocol>
@end

@implementation KakaSurfaceComponentView

- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    _props = KakaSurfaceShadowNode::defaultSharedProps();
    self.contentView = [[KakaOfflineView alloc] initWithFrame:CGRectZero];
  }
  return self;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<KakaSurfaceComponentDescriptor>();
}

@end
