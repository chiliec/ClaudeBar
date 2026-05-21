import Testing
import Foundation

@Suite
struct AppcastTests {
    private static let appcastURL: URL = {
        // appcast.xml lives at the package root, two levels up from Tests/
        let file = URL(fileURLWithPath: #filePath)
        return file
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
            .appendingPathComponent("appcast.xml")
    }()

    @Test func appcastParsesAsValidXML() throws {
        let data = try Data(contentsOf: Self.appcastURL)
        let parser = XMLParser(data: data)
        let delegate = ValidatingDelegate()
        parser.delegate = delegate
        #expect(parser.parse(), "appcast.xml must parse as valid XML")
        #expect(delegate.sawChannel, "appcast must contain an <rss><channel> element")
    }

    @Test func everyItemHasRequiredSparkleFields() throws {
        let items = try Self.parseItems()
        for item in items {
            #expect(!(item.version ?? "").isEmpty,
                    "item missing <sparkle:version>: \(item)")
            #expect(item.enclosureURL?.isEmpty == false,
                    "item missing <enclosure url=...>: \(item)")
            #expect(item.edSignature?.isEmpty == false,
                    "item missing sparkle:edSignature on enclosure: \(item)")
        }
    }

    @Test func topmostItemMatchesInfoPlistVersion() throws {
        let items = try Self.parseItems()
        guard let top = items.first else {
            // Empty appcast: trivially valid until the first release lands.
            return
        }
        let plistVersion = try Self.infoPlistShortVersion()
        let message: Comment = "appcast top item is \(top.version ?? "nil") but Info.plist is \(plistVersion). Release script must bump both together."
        #expect(top.version == plistVersion, message)
    }

    // MARK: - Helpers

    private struct AppcastItem {
        var version: String?
        var enclosureURL: String?
        var edSignature: String?
    }

    private static func parseItems() throws -> [AppcastItem] {
        let data = try Data(contentsOf: appcastURL)
        let parser = XMLParser(data: data)
        let collector = ItemCollector()
        parser.delegate = collector
        guard parser.parse() else { throw NSError(domain: "AppcastTests", code: 1) }
        return collector.items
    }

    private static func infoPlistShortVersion() throws -> String {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ClaudeBar/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization
            .propertyList(from: data, options: [], format: nil) as? [String: Any]
        guard let v = plist?["CFBundleShortVersionString"] as? String else {
            throw NSError(domain: "AppcastTests", code: 2)
        }
        return v
    }

    private final class ValidatingDelegate: NSObject, XMLParserDelegate {
        var sawChannel = false
        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            if elementName == "channel" { sawChannel = true }
        }
    }

    private final class ItemCollector: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var currentElement: String?
        private var currentValue: String = ""

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            currentElement = elementName
            currentValue = ""
            switch elementName {
            case "item":
                current = AppcastItem()
            case "enclosure":
                current?.enclosureURL = attributeDict["url"]
                current?.edSignature = attributeDict["sparkle:edSignature"]
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentValue += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch elementName {
            case "sparkle:version":
                current?.version = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            case "item":
                if let item = current { items.append(item) }
                current = nil
            default:
                break
            }
            currentElement = nil
        }
    }
}
