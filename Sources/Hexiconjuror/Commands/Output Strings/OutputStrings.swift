import Commandant
import Foundation

final class OutputStrings: ConjurorCommand {
    typealias ClientError = ConjurorError

    struct Options: OptionsProtocol {
        typealias ClientError = ConjurorError

        static func create(_ definitionsPath: String) -> (String) -> (String) -> (Bool) -> Options {
            { resourcesPath in { language in { Options(definitionsPath: definitionsPath, resourcesPath: resourcesPath, language: language, stripEmptyComments: $0) } } }
        }

        static func evaluate(_ m: CommandMode) -> Result<OutputStrings.Options, CommandantError<ConjurorError>> {
            create
                <*> m <| Option(key: "def-path", defaultValue: "", usage: "Relative path to the files which contain the string definition namespaces.")
                <*> m <| Option(key: "res-path", defaultValue: "", usage: "Relative path to the strings files.")
                <*> m <| Option(key: "lang", defaultValue: "en", usage: "The development language for the project (the default lproj.) Defaults to 'en'.")
                <*> m <| Switch(key: "strip-comments", usage: "Whether to remove from the output file any strings which have no engineer-provided comment.")
        }

        let definitionsPath: String
        let resourcesPath: String
        let language: String
        let stripEmptyComments: Bool

    }

    let verb = "output-strings"
    let function = "Outputs and sorts all localized strings into their respective tables, preserving existing and deleting unused translations."
    private let parser = StringsParser()

    func run(_ options: OutputStrings.Options) -> Result<(), ConjurorError> {
        let sourceFiles = FileManager.default.enumerator(at: environment.projectPath.appendingPathComponent(options.definitionsPath), includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        let stringsFiles = FileManager.default.enumerator(at: environment.projectPath.appendingPathComponent(options.resourcesPath), includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "strings" } ?? []
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Result {
            try FileManager.default.createDirectory(atPath: temporaryDirectory.path, withIntermediateDirectories: false, attributes: nil)
        }
            .flatMapCatching { files in
                let localize = Process()
                let arguments = "/usr/bin/xcrun extractLocStrings -o \(temporaryDirectory.path)"
                    .split(separator: " ").map(String.init)
                    + sourceFiles.map { $0.path }
                localize.executableURL = URL(fileURLWithPath: arguments[0])
                localize.arguments = Array(arguments.dropFirst())
                try localize.run()
                localize.waitUntilExit()
            }
            .flatMapCatching {
                let existingStrings = try stringsFiles.map {
                    try Table(url: $0, strings: parser.parse(file: $0))
                }
                let newStrings = try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [])
                    .filter { $0.pathExtension == "strings" }
                    .map { return try Table(url: $0, strings: parser.parse(file: $0)) }
                return newStrings.map { new in
                    guard var existing = existingStrings.first(where: { $0.name == new.name }) else { return new }
                    new.strings.forEach {
                        if existing.strings[$0.key] != nil { return }
                        existing.strings[$0.key] = $0.value
                    }
                    return existing
                } as [Table]
            }
            .flatMapCatching { (tables: [Table]) in
                try tables.forEach { table in
                    let oldFile = temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    let tempFile = temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    FileManager.default.createFile(atPath: tempFile.path, contents: nil, attributes: nil)
                    try table.write(to: tempFile)
                    try FileManager.default.moveItem(at: table.url, to: oldFile)
                    do {
                        try FileManager.default.moveItem(at: tempFile, to: table.url)
                    } catch {
                        try FileManager.default.moveItem(at: oldFile, to: table.url)
                    }
                }
            }
            .mapError { _ in ConjurorError.invalidArguments }
    }


}

extension OutputStrings {

    private struct Table {

        var url: URL
        var strings: [String: LocalizedString]

        var name: String {
            url.lastPathComponent.components(separatedBy: ".").first ?? ""
        }

        func write(to url: URL) throws {
            var stream = try FileOutputStream(url: url)
            strings.sorted(by: \.key).map(\.value).map {
                [$0.comment, #""\#($0.key)" = "\#($0.value)";"#, "\n"].joined(separator: "\n")
            }
                .joined()
                .write(to: &stream)
        }

    }

    private struct LocalizedString {
        var comment: String
        var key: String
        var value: String
    }


    private class StringsParser {

        enum Error: Swift.Error {
            case malformedFile(encountered: [String: LocalizedString])
            case unexpectedToken
            case missingToken
        }

        func parse(file url: URL) throws -> [String: LocalizedString] {
            var strings = [String: LocalizedString]()
            var fileContents = try String(contentsOf: url)
            var comments = [String]()
            while fileContents.count > 0 {
                if fileContents.hasPrefix("/*") {
                    do {
                        try comments.append(parseComment(from: &fileContents))
                    } catch {
                        throw Error.malformedFile(encountered: strings)
                    }
                } else if fileContents.hasPrefix("\"") {
                    do {
                        let localizedString = try parseLocalizedString(from: &fileContents, with: comments)
                        strings[localizedString.key] = localizedString
                        comments.removeAll()
                    } catch {
                        throw Error.malformedFile(encountered: strings)
                    }
                } else if fileContents.hasWhitespacePrefix {
                    fileContents.removeFirst()
                } else {
                    throw Error.malformedFile(encountered: strings)
                }
            }
            return strings
        }

        private func parseComment(from fileContents: inout String) throws -> String {
            var comment = ""
            try expect(token: "/*", in: &fileContents)
            while fileContents.occupiedWithoutPrefix("*/") {
                comment.append(fileContents.removeFirst())
            }
            if fileContents.count == 0 { throw Error.missingToken }
            fileContents = String(fileContents.dropFirst(2))
            return comment
        }

        private func parseLocalizedString(from fileContents: inout String, with comments: [String]) throws -> LocalizedString {
            var key = ""
            var value = ""
            try expect(token: "\"", in: &fileContents)
            while fileContents.occupiedWithoutPrefix("\"") {
                key.append(fileContents.removeFirst())
            }
            if fileContents.count == 0 { throw Error.missingToken }
            fileContents.removeFirst()
            try expect(token: "=", in: &fileContents)
            try expect(token: "\"", in: &fileContents)
            while fileContents.occupiedWithoutPrefix("\"") {
                value.append(fileContents.removeFirst())
            }
            if fileContents.count == 0 { throw Error.missingToken }
            fileContents.removeFirst()
            try expect(token: ";", in: &fileContents)
            return LocalizedString(comment: "/*\(comments.joined())*/", key: key, value: value)
        }

        private func expect(token: String, in string: inout String) throws {
            while string.occupiedWithoutPrefix(token) {
                if string.hasWhitespacePrefix { string.removeFirst() }
                else { throw Error.unexpectedToken }
            }
            if string.count == 0 { throw Error.missingToken }
            string = String(string.dropFirst(token.count))
        }

    }

}