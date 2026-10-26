#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A File Provider's view of one item: what Finder reads to build its menu and badges.
@interface FPBItem : NSObject
@property (readonly, copy) NSString *itemIdentifier;
@property (readonly, copy) NSString *domainIdentifier;
/// The provider's own flags (OneDrive: `showShare`, `showViewOnline`, `showPinUnpin`…).
@property (readonly, copy, nullable) NSDictionary *userInfo;
/// Decoration identifiers (OneDrive: `com.microsoft.OneDrive.FileProviderBadges.Pinned`…).
@property (readonly, copy) NSArray<NSString *> *decorations;
/// `NSFileProviderContentPolicy`: 3 = download eagerly and keep downloaded (pinned).
@property (readonly) NSInteger contentPolicy;
/// The framework's item, for evaluating providers' action rules as Finder does.
@property (readonly) id object;
@end

/// The File Provider domain an item belongs to, and the extension serving it.
@interface FPBDomain : NSObject
@property (readonly, copy) NSString *identifier;
@property (readonly, copy, nullable) NSURL *extensionBundleURL;
@property (readonly, copy, nullable) NSDictionary *userInfo;
@end

/// Finder's way into File Provider actions (OneDrive's Share, View online, Always keep on this
/// device…) and pinned state: private FileProvider.framework classes, looked up by name and
/// checked before every use. Every method fails softly (nil, NO, an error) when they're
/// missing or misbehave, and never lets an Objective-C exception through.
@interface FPBBridge : NSObject
/// Whether the private classes and methods this needs are all there.
@property (class, readonly) BOOL isAvailable;
/// `nil` outside File Provider domains. Synchronous, ~1 ms: an XPC call to fileproviderd.
+ (nullable FPBItem *)itemForURL:(NSURL *)url;
+ (nullable FPBDomain *)domainForURL:(NSURL *)url;
/// `nil` if `format` isn't a valid predicate.
+ (nullable NSPredicate *)predicateWithFormat:(NSString *)format;
/// NO if evaluating throws.
+ (BOOL)evaluatePredicate:(NSPredicate *)predicate withObject:(id)object NS_SWIFT_NAME(evaluate(_:with:));
/// Runs a provider-declared action, as Finder's menu does. The completion handler runs on an
/// arbitrary queue once the provider has taken the action; it does the work afterwards.
+ (void)performAction:(NSString *)actionIdentifier
     domainIdentifier:(NSString *)domainIdentifier
      itemIdentifiers:(NSArray<NSString *> *)itemIdentifiers
           completion:(void (^)(NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
