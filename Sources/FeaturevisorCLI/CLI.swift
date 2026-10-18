import Foundation

struct CLI {
    func run(args: [String]) -> Int32 {
        if args.first == "help" {
            if args.count == 1 { printHelp(); return 0 }
            if args.count == 2 && ["test", "benchmark", "assess-distribution"].contains(args[1]) {
                return run(args: [args[1], "--help"])
            }
            fputs("Unexpected help arguments\n", stderr)
            return 1
        }
        let options = CLIParser.parse(args)
        if let error = options.error {
            fputs("\(error)\n", stderr)
            return 1
        }
        if !options.command.isEmpty && !["test", "benchmark", "assess-distribution"].contains(options.command) {
            fputs("Unknown command: \(options.command)\n", stderr)
            return 1
        }
        if options.help || args.isEmpty { printHelp(); return 0 }

        switch options.command {
        case "test":
            return TestCommand().run(options)
        case "benchmark":
            return BenchmarkCommand().run(options)
        case "assess-distribution":
            return AssessDistributionCommand().run(options)
        default:
            fputs("A command is required. Use --help for usage.\n", stderr)
            return 1
        }
    }

    private func printHelp() {
        print("""
        Usage: featurevisor <test|benchmark|assess-distribution> [options]
        Node.js handles project parsing and datafiles. This CLI evaluates with the Swift SDK.

        Project: --project-directory-path PATH (also --root-directory-path)
                 --set SET --environment ENV --target TARGET (repeatable)
        Test: --key-pattern REGEX --assertion-pattern REGEX --entity-type TYPE --case ID
              --only-failures --show-datafile --json --pretty --coverage --uncovered
        Benchmark: --feature KEY or --variable KEY, --variation, --context JSON
        Assess distribution: --feature KEY --context JSON --populate-uuid KEY (repeatable)
        Measurement: --n N or -n N (default 1000), --inflate N (positive integers)
        Output: --quiet --verbose
        Help: --help or -h

        Value options accept =value or a separate value. Repeat selectors in order.
        CamelCase names remain supported. Boolean flags also accept =true or =false.
        Legacy --with-scopes, --with-tags and --schema-version remain accepted and ignored.
        Learn more at https://featurevisor.com/docs/sdks/swift/
        """)
    }
}
