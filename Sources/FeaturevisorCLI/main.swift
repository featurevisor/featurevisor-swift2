import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let cli = CLI()
exit(cli.run(args: args))
