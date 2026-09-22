#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Authentication type for the Wi-Fi network.
 */
typedef NS_ENUM(NSInteger, GCKSecurePairingWiFiAuthType) {
  GCKSecurePairingWiFiAuthTypeUnspecified = 0,
  GCKSecurePairingWiFiAuthTypeOpen = 1,
  GCKSecurePairingWiFiAuthTypeWEP = 2,
  GCKSecurePairingWiFiAuthTypeWPA = 3,
};

/**
 * Completion handler for Wi-Fi network connection.
 *
 * @param success YES if the connection succeeded, NO otherwise.
 * @param error The error on failure, or nil on success.
 */
typedef void (^GCKSecurePairingWiFiConnectorCompletionHandler)(BOOL success,
                                                               NSError *_Nullable error);

/**
 * Protocol defining the network connector used to join a Wi-Fi network.
 */
@protocol GCKSecurePairingWiFiConnectorProtocol <NSObject>

/**
 * Initiates a connection to a Wi-Fi network with the given SSID and password.
 *
 * @param SSID The SSID of the Wi-Fi network to join.
 * @param password The password for the Wi-Fi network.
 * @param authType The authentication type for the network.
 * @param completion A block to be called upon completion, indicating success or failure.
 */
- (void)joinNetworkWithSSID:(NSString *)SSID
                   password:(nullable NSString *)password
                   authType:(GCKSecurePairingWiFiAuthType)authType
                 completion:(GCKSecurePairingWiFiConnectorCompletionHandler)completion;

@end

NS_ASSUME_NONNULL_END
