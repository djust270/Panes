#import "FileProviderBridge.h"

#if !__has_feature(objc_arc)
#error "FileProviderBridge needs ARC"
#endif

// The private methods used, declared so ARC knows their memory semantics (alloc/init families,
// out-parameters). Properties are read with KVC instead, as their types aren't public.
@interface NSObject (FPBPrivate)
+ (instancetype)defaultManager;
- (nullable id)itemForURL:(NSURL *)url error:(NSError **)error;
- (void)addOperation:(NSOperation *)operation;
+ (nullable id)providerDomainForURL:(NSURL *)url error:(NSError **)error;
- (instancetype)initWithActionIdentifier:(NSString *)actionIdentifier
                        providerDomainID:(NSString *)providerDomainID
                         itemIdentifiers:(NSArray<NSString *> *)itemIdentifiers;
- (void)setActionCompletionBlock:(void (^)(id _Nullable))block;
@end

static Class ItemManagerClass(void) { return NSClassFromString(@"FPItemManager"); }
static Class DomainClass(void) { return NSClassFromString(@"FPProviderDomain"); }
static Class VendorActionClass(void) { return NSClassFromString(@"FPVendorDefinedActionOperation"); }

static id _Nullable ItemManager(void) {
    Class cls = ItemManagerClass();
    return [cls respondsToSelector:@selector(defaultManager)] ? [cls defaultManager] : nil;
}

static id _Nullable Value(id object, NSString *key, Class expected) {
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:expected] ? value : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

static NSError *UnavailableError(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil];
}

@interface FPBItem ()
- (nullable instancetype)initWithObject:(id)object;
@end

@implementation FPBItem

- (nullable instancetype)initWithObject:(id)object {
    NSString *itemIdentifier = Value(object, @"itemIdentifier", NSString.class);
    NSString *domainIdentifier = Value(object, @"providerDomainID", NSString.class);
    if (!itemIdentifier || !domainIdentifier) return nil;
    if ((self = [super init])) {
        _object = object;
        _itemIdentifier = [itemIdentifier copy];
        _domainIdentifier = [domainIdentifier copy];
        _userInfo = [Value(object, @"userInfo", NSDictionary.class) copy];
        NSMutableArray<NSString *> *decorations = [NSMutableArray array];
        for (id decoration in Value(object, @"decorations", NSArray.class) ?: @[]) {
            if ([decoration isKindOfClass:NSString.class]) [decorations addObject:decoration];
        }
        _decorations = [decorations copy];
        _contentPolicy = [Value(object, @"contentPolicy", NSNumber.class) integerValue];
    }
    return self;
}

@end

@interface FPBDomain ()
- (nullable instancetype)initWithObject:(id)object;
@end

@implementation FPBDomain

- (nullable instancetype)initWithObject:(id)object {
    NSString *identifier = Value(object, @"identifier", NSString.class);
    if (!identifier) return nil;
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _extensionBundleURL = [Value(object, @"extensionBundleURL", NSURL.class) copy];
        _userInfo = [Value(object, @"domainUserInfo", NSDictionary.class) copy];
    }
    return self;
}

@end

@implementation FPBBridge

+ (BOOL)isAvailable {
    Class manager = ItemManagerClass();
    return [manager respondsToSelector:@selector(defaultManager)]
        && [manager instancesRespondToSelector:@selector(itemForURL:error:)]
        && [manager instancesRespondToSelector:@selector(addOperation:)]
        && [DomainClass() respondsToSelector:@selector(providerDomainForURL:error:)]
        && [VendorActionClass() instancesRespondToSelector:
                @selector(initWithActionIdentifier:providerDomainID:itemIdentifiers:)]
        && [VendorActionClass() isSubclassOfClass:NSOperation.class];
}

+ (nullable FPBItem *)itemForURL:(NSURL *)url {
    id manager = ItemManager();
    if (![manager respondsToSelector:@selector(itemForURL:error:)]) return nil;
    @try {
        NSError *error = nil;
        id item = [manager itemForURL:url error:&error];
        return item ? [[FPBItem alloc] initWithObject:item] : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (nullable FPBDomain *)domainForURL:(NSURL *)url {
    Class cls = DomainClass();
    if (![cls respondsToSelector:@selector(providerDomainForURL:error:)]) return nil;
    @try {
        NSError *error = nil;
        id domain = [cls providerDomainForURL:url error:&error];
        return domain ? [[FPBDomain alloc] initWithObject:domain] : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (nullable NSPredicate *)predicateWithFormat:(NSString *)format {
    @try {
        return [NSPredicate predicateWithFormat:format argumentArray:nil];
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (BOOL)evaluatePredicate:(NSPredicate *)predicate withObject:(id)object {
    @try {
        return [predicate evaluateWithObject:object];
    } @catch (NSException *exception) {
        return NO;
    }
}

+ (void)performAction:(NSString *)actionIdentifier
     domainIdentifier:(NSString *)domainIdentifier
      itemIdentifiers:(NSArray<NSString *> *)itemIdentifiers
           completion:(void (^)(NSError *_Nullable))completion {
    id manager = ItemManager();
    if (!self.isAvailable || !manager) {
        completion(UnavailableError());
        return;
    }
    @try {
        NSOperation *operation = [[VendorActionClass() alloc] initWithActionIdentifier:actionIdentifier
                                                                       providerDomainID:domainIdentifier
                                                                        itemIdentifiers:itemIdentifiers];
        // The action's own completion block may carry an error; its exact signature isn't
        // public, so it's only trusted for an NSError. NSOperation's completion block then
        // reports, once.
        __block NSError *failure = nil;
        if ([operation respondsToSelector:@selector(setActionCompletionBlock:)]) {
            [operation setActionCompletionBlock:^(id _Nullable result) {
                if ([result isKindOfClass:NSError.class]) failure = result;
            }];
        }
        operation.completionBlock = ^{
            completion(failure);
        };
        [manager addOperation:operation];
    } @catch (NSException *exception) {
        completion(UnavailableError());
    }
}

@end
