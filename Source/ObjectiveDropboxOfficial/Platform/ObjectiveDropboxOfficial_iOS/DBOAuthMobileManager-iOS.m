///
/// Copyright (c) 2016 Dropbox, Inc. All rights reserved.
///

#import "DBOAuthMobileManager-iOS.h"
#import "DBOAuthManager+Protected.h"
#import "DBOAuthMobile-iOS.h"
#import "DBOAuthResult.h"
#import "DBSharedApplicationProtocol.h"
#import "DBTokenAccessType.h"
#include <CommonCrypto/CommonDigest.h>

#pragma mark - OAuth manager base (iOS)

static NSString *const kDBLinkNonce = @"dropbox.sync.nonce";
static NSString *const kCodeVerifierValidCharacters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~";
static const NSInteger kCodeVerifierLength = 128;
static NSString *const kPKCECodeChallengeMethod = @"S256";


@implementation DBOAuthMobileManager {
    NSURL *_dauthRedirectURL;
}

- (instancetype)initWithAppKey:(NSString *)appKey {
    return [self initWithAppKey:appKey host:nil];
}

- (instancetype)initWithAppKey:(NSString *)appKey host:(NSString *)host {
    return [self initWithAppKey:appKey host:host redirectURL:nil];
}

- (instancetype)initWithAppKey:(NSString *)appKey host:(NSString *)host redirectURL:(NSString *)redirectURL {
    self = [super initWithAppKey:appKey host:host redirectURL:redirectURL];
    if (self) {
        _dauthRedirectURL = [NSURL URLWithString:[NSString stringWithFormat:@"db-%@://1/connect", appKey]];
        [_urls addObject:_dauthRedirectURL];
    }
    return self;
}

- (DBOAuthResult *)extractFromUrl:(NSURL *)url {
    DBOAuthResult *result;
    if ([url.host isEqualToString:@"1"]) { // dauth
        result = [self extractfromDAuthURL:url];
    } else {
        result = [self extractFromRedirectURL:url];
    }
    return result;
}

- (BOOL)checkAndPresentPlatformSpecificAuth:(id<DBSharedApplication>)sharedApplication {
    if (![self hasApplicationQueriesSchemes]) {
        NSString *message = @"DropboxSDK: unable to link; app isn't registered to query for URL schemes dbapi-2 and "
        @"dbapi-8-emm. In your project's Info.plist file, add a \"dbapi-2\" value and a "
        @"\"dbapi-8-emm\" value associated with the following keys: \"Information Property List\" > "
        @"\"LSApplicationQueriesSchemes\" > \"Item <N>\" and \"Item <N+1>\".";
        NSString *title = @"ObjectiveDropbox Error";
        [sharedApplication presentErrorMessage:message title:title];
        return YES;
    }

    NSString *scheme = [self dAuthScheme:sharedApplication];

    if (scheme != nil) {
        [sharedApplication presentExternalApp:[self dAuthURL:scheme includeNonce:YES]];
        return YES;
    }

    return NO;
}

- (DBOAuthResult *)handleRedirectURL:(NSURL *)url {
    [[DBMobileSharedApplication mobileSharedApplication] dismissAuthController];
    DBOAuthResult *result = [super handleRedirectURL:url];
    return result;
}

- (NSString *)createCodeVerifier {
    // Generate random string from allowable characters of specified length
    unichar randomChars[kCodeVerifierLength];
    for (NSInteger i = 0; i < kCodeVerifierLength; i++) {
        randomChars[i] = [kCodeVerifierValidCharacters
                          characterAtIndex:(NSUInteger) (arc4random_uniform((uint32_t) kCodeVerifierValidCharacters.length))];
    }
    return [NSString stringWithCharacters:randomChars length:kCodeVerifierLength];
}

- (NSString *)codeChallengeFromVerifier:(NSString *)codeVerifier {
    // Encode sha256 hash of the verifier string
    NSData *codeVerifierData = [codeVerifier dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *hashedVerifierData = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(codeVerifierData.bytes, (CC_LONG) codeVerifierData.length, hashedVerifierData.mutableBytes);
    NSString *codeChallenge = [hashedVerifierData base64EncodedStringWithOptions:0];
    // Remove trailing equal
    if ([codeChallenge hasSuffix:@"="]) {
        codeChallenge = [codeChallenge substringToIndex:(codeChallenge.length - 1)];
    }

    return codeChallenge;
}

- (NSString *)createAndStorePKCEStateNonce {
    NSString *codeVerifier = [self createCodeVerifier];
    [[NSUserDefaults standardUserDefaults] setObject:codeVerifier forKey:kDBLinkNonce];

    NSString *codeChallenge = [self codeChallengeFromVerifier:codeVerifier];
    return [NSString stringWithFormat:@"oauth2code:%@:%@:%@",
            codeChallenge,
            kPKCECodeChallengeMethod,
            self.tokenAccessType];


}

- (NSString *)createAndStoreLegacyOAuth2StateNonce {
    NSString *nonce = [[NSUUID alloc] init].UUIDString;
    [[NSUserDefaults standardUserDefaults] setObject:nonce forKey:kDBLinkNonce];
    return [NSString stringWithFormat:@"oauth2:%@", nonce];
}

- (NSURL *)dAuthURL:(NSString *)scheme includeNonce:(BOOL)includeNonce {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = scheme;
    components.host = @"1";
    components.path = @"/connect";

    if (includeNonce) {
        NSString *state = nil;
        if (self.tokenAccessType) {
            state = [self createAndStorePKCEStateNonce];
        } else {
            state = [self createAndStoreLegacyOAuth2StateNonce];
        }

        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"k" value:_appKey],
            [NSURLQueryItem queryItemWithName:@"s" value:@""],
            [NSURLQueryItem queryItemWithName:@"state" value:state],
        ];
    }
    return components.URL;
}

- (NSString *)dAuthScheme:(id<DBSharedApplication>)sharedApplication {
    if ([sharedApplication canPresentExternalApp:[self dAuthURL:@"dbapi-2" includeNonce:NO]]) {
        return @"dbapi-2";
    } else if ([sharedApplication canPresentExternalApp:[self dAuthURL:@"dbapi-8-emm" includeNonce:NO]]) {
        return @"dbapi-8-emm";
    } else {
        return nil;
    }
}

- (DBOAuthResult *)extractfromDAuthURL:(NSURL *)url {
    NSString *path = url.path;
    if (path != nil) {
        if ([path isEqualToString:@"/connect"]) {
            NSMutableDictionary<NSString *, NSString *> *results = [[NSMutableDictionary alloc] init];
            NSArray<NSString *> *pairs = [url.query componentsSeparatedByString:@"&"] ?: @[];

            for (NSString *pair in pairs) {
                NSArray *kv = [pair componentsSeparatedByString:@"="];
                [results setObject:[kv objectAtIndex:1] forKey:[kv objectAtIndex:0]];
            }
            NSArray<NSString *> *state = [results[@"state"] componentsSeparatedByString:@"%3A"];

            NSString *nonce = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:kDBLinkNonce];
            if (state.count == 2 && [state[0] isEqualToString:@"oauth2"] && [state[1] isEqualToString:nonce]) {
                NSString *accessToken = results[@"oauth_token_secret"];
                NSString *uid = results[@"uid"];
                return [[DBOAuthResult alloc] initWithSuccess:[[DBAccessToken alloc] initWithAccessToken:accessToken uid:uid]];
            } else {
                return [[DBOAuthResult alloc] initWithError:@"" errorDescription:@"Unable to verify link request."];
            }
        }
    }

    return nil;
}

- (BOOL)hasApplicationQueriesSchemes {
    NSArray<NSString *> *queriesSchemes =
    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"LSApplicationQueriesSchemes"];
    BOOL foundApi2 = NO;
    BOOL foundApi8Emm = NO;
    for (NSString *scheme in queriesSchemes) {
        if ([scheme isEqualToString:@"dbapi-2"]) {
            foundApi2 = YES;
        } else if ([scheme isEqualToString:@"dbapi-8-emm"]) {
            foundApi8Emm = YES;
        }
        if (foundApi2 && foundApi8Emm) {
            return YES;
        }
    }
    return NO;
}

@end
