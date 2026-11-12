#import "Aplyna.h"
#import <AplynaSpec/AplynaSpec.h>
#import "AplynaReactNative-Swift.h"

@interface Aplyna () <NativeAplynaSpec>
@end

@implementation Aplyna {
  AplynaReactNativeAdapter *_adapter;
}
RCT_EXPORT_MODULE(Aplyna)
+ (BOOL)requiresMainQueueSetup { return NO; }
- (instancetype)init {
  if (self = [super init]) { _adapter = [AplynaReactNativeAdapter new]; }
  return self;
}
- (void)invoke:(NSString *)method argumentsJSON:(NSString *)argumentsJSON resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  [_adapter invoke:method argumentsJSON:argumentsJSON resolve:resolve reject:reject];
}
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeAplynaSpecJSI>(params);
}
@end
