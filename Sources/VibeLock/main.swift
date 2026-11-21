import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
    do { try LockStatusService.shared.start() }
    catch { fputs("Network lock status service could not start.\n", stderr) }
}
dispatchMain()
