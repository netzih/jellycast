import SwiftUI
import GoogleCast
import Intents

@main
struct JellyCastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(appState)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let playMediaHandler = PlayMediaIntentHandler()

    /// Siri's "play … on JellyCast" arrives here, with the app launched in the
    /// background if it wasn't running.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? playMediaHandler : nil
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must run before any Cast API or GCKUICastButton is touched.
        //
        // kGCKDefaultMediaReceiverApplicationID is Google's stock receiver. It
        // plays plain media URLs and supports queues, so no registered receiver
        // app (and no $5 Cast developer registration) is needed.
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        // Keep the session alive in the background so the speaker keeps playing
        // while the phone is locked.
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)

        return true
    }
}
