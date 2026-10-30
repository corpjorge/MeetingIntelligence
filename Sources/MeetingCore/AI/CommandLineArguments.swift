public import Foundation

public struct CommandLineArgumentError: LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct CommandLineArguments: Sendable, Equatable {
    public struct Specification: Sendable {
        public var valueOptions: Set<String>
        public var flags: Set<String>

        public init(valueOptions: Set<String>, flags: Set<String>) {
            self.valueOptions = valueOptions
            self.flags = flags
        }

        public static let mi = Specification(
            valueOptions: ["title", "meeting", "speaker", "floor", "format", "out", "provider", "model", "effort",
                           "reference", "rttm"],
            flags: ["no-process", "no-diarize", "no-local-diarization", "boost-vocabulary", "semantic", "share", "save"])
    }

    public var positional: [String]
    public var options: [String: String]
    public var flags: Set<String>

    public init(positional: [String] = [], options: [String: String] = [:], flags: Set<String> = []) {
        self.positional = positional
        self.options = options
        self.flags = flags
    }

    public init(parsing raw: [String], specification: Specification) throws {
        self.init()
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            index += 1
            if argument == "--" {
                positional += raw[index...]
                break
            }
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                continue
            }
            var key = String(argument.dropFirst(2))
            var inlineValue: String?
            if let equals = key.firstIndex(of: "=") {
                inlineValue = String(key[key.index(after: equals)...])
                key = String(key[..<equals])
            }
            if specification.flags.contains(key) {
                guard inlineValue == nil else { throw CommandLineArgumentError("--\(key) no admite un valor.") }
                flags.insert(key)
            } else if specification.valueOptions.contains(key) {
                let value: String?
                if let inlineValue {
                    value = inlineValue
                } else if index < raw.count, !raw[index].hasPrefix("--") {
                    value = raw[index]
                    index += 1
                } else {
                    value = nil
                }
                guard let value, !value.isEmpty else { throw CommandLineArgumentError("--\(key) requiere un valor.") }
                options[key] = value
            } else {
                throw CommandLineArgumentError("Opción desconocida: --\(key)")
            }
        }
    }
}
