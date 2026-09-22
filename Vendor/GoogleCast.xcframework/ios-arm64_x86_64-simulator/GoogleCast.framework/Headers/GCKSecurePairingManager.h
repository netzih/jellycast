#import <Foundation/Foundation.h>

#import <GoogleCast/GCKDevice.h>
#import "GCKSecurePairingWiFiConnectorProtocol.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Completion block for startPairingWithURL.
 *
 * @param device The paired device on success, or nil on failure.
 * @param error The error on failure, or nil on success.
 */
typedef void (^GCKSecurePairingCompletionHandler)(GCKDevice *_Nullable device, NSError *_Nullable error);

/**
 * Completion block for connectToPairedDevice.
 *
 * @param success YES if the connection succeeded, NO otherwise.
 * @param error The error on failure, or nil on success.
 */
typedef void (^GCKSecurePairingConnectionCompletionHandler)(BOOL success, NSError *_Nullable error);

/**
 * Completion block for fetchPairedDevicesForCurrentNetworkWithCompletion.
 *
 * @param devices The list of paired devices found, or nil if an error occurred.
 * @param error The error on failure, or nil on success.
 */
typedef void (^GCKSecurePairingDevicesCompletionHandler)(NSArray<GCKDevice *> *_Nullable devices,
                                                         NSError *_Nullable error);

/**
 * The central manager class responsible for orchestrating the Secure Pairing process.
 * It handles decoding the QR code URI, orchestrating the pairing key generation,
 * and executing the device authentication challenge.
 */
@interface GCKSecurePairingManager : NSObject

/** The Wi-Fi connector used by the manager to join networks. */
@property(nonatomic, strong, readonly) id<GCKSecurePairingWiFiConnectorProtocol> wifiConnector;

/**
 * The list of currently trusted and paired receiver devices. Returns nil if the database
 * is not yet initialized and ready.
 */
@property(nonatomic, copy, readonly, nullable) NSArray<GCKDevice *> *pairedDevices;

/**
 * Initializes the manager with the provided Wi-Fi connector.
 *
 * @param wifiConnector The connector to use for joining networks.
 */
- (instancetype)initWithWiFiConnector:(id<GCKSecurePairingWiFiConnectorProtocol>)wifiConnector;

/** Default initializer is unavailable. Use initWithWiFiConnector: instead. */
- (instancetype)init NS_UNAVAILABLE;

/**
 * Initiates the Pairing Mode workflow using the connection parameters extracted from the receiver's
 * QR code.
 *
 * Always invoke from the main thread.
 *
 * @param url The pairing URL containing connection parameters.
 * @param completion The completion block invoked with the paired device on success, or an error on
 * failure.
 */
- (void)startPairingWithURL:(NSString *)url
                 completion:(GCKSecurePairingCompletionHandler)completion;

/**
 * Triggers the Paired Mode flow for a previously authenticated device.
 *
 * @param device The device to connect to.
 * @param completion The completion block invoked with success status and optional error.
 */
- (void)connectToPairedDevice:(GCKDevice *)device
                   completion:(GCKSecurePairingConnectionCompletionHandler)completion;

/**
 * Asynchronously fetches the list of currently paired receiver devices that are active and
 * reachable in the current network environment.
 *
 * @param completion The completion block invoked with the list of paired devices on success,
 * or an error on failure.
 */
- (void)fetchPairedDevicesForCurrentNetworkWithCompletion:
    (GCKSecurePairingDevicesCompletionHandler)completion;

@end

NS_ASSUME_NONNULL_END
