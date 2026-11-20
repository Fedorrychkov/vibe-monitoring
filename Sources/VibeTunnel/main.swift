import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
    do { try VPNCredentialService.shared.start() }
    catch { fputs("VPN credential service could not start.\n", stderr) }
}
dispatchMain()
