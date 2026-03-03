import Foundation

struct CLI {
    func run(args: [String]) -> Int32 {
        let options = CLIParser.parse(args)

        switch options.command {
        case "test":
            return TestCommand().run(options)
        case "benchmark":
            return BenchmarkCommand().run(options)
        case "assess-distribution":
            return AssessDistributionCommand().run(options)
        default:
            print("Learn more at https://featurevisor.com/docs/sdks/go/")
            return 0
        }
    }
}
