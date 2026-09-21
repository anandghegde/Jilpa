// `jilpa`: thin client over the local socket. Holds no permissions and no logic. The commands
// (`jilpa go`, `jilpa fav add .`, `jilpa recent --json`, `jilpa context use`) land with WP16.

import Foundation
import JilpaIPC

FileHandle.standardError.write(Data("jilpa: the automation surface is not implemented yet (WP16)\n".utf8))
exit(64)
