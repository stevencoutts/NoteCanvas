import Foundation
import PageModel
import Store
import CanvasKit

checkEqual(Frame(x: 1, y: 2, width: 3, height: 4).width, 3, "harness sanity")

modelChecks()
storeChecks()
encryptionChecks()
assetAndSectionChecks()
lastNotebookChecks()
bridgeChecks()
updateChecks()
oneStorePrimitiveChecks()
oneStoreObjectChecks()
corpusChecks()
oneImportTextChecks()
oneImportLayoutChecks()
oneImportStyleLossChecks()
oneImportHostileLayoutChecks()
corpusImportChecks()

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
