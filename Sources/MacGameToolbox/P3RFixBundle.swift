import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

enum BundledP3RFixPayload {
    static func load() throws -> P3RFixPayload {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let dllURL = bundle.url(forResource: "dsound", withExtension: "dll", subdirectory: "P3RFix"),
              let asiURL = bundle.url(forResource: "P3RFix", withExtension: "asi", subdirectory: "P3RFix") else {
            throw DirectLaunchWorkflowError.aspectFixPayloadMissing
        }
        return try P3RFixPayload(
            dsoundDLL: Data(contentsOf: dllURL),
            asi: Data(contentsOf: asiURL)
        ).verified()
    }
}
