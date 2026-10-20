#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// Exposes the Swift class in RNDropplink.swift to React Native. Selectors must match its @objc names.
@interface RCT_EXTERN_MODULE(RNDropplink, RCTEventEmitter)

RCT_EXTERN_METHOD(initializeSdk:(NSDictionary *)config
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(handleDeepLink:(NSString *)url
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getAttribution:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getInstallId:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(setDeepLinkListenerEnabled:(BOOL)enabled)

// addListener: / removeListeners: are inherited from RCTEventEmitter.

@end
