import Foundation
import PageModel

checkEqual(Frame(x: 1, y: 2, width: 3, height: 4).width, 3, "harness sanity")

modelChecks()

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
