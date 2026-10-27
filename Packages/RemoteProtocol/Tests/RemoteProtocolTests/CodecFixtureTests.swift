import Foundation
import RemoteProtocol
import Testing

@Suite("Reference format v1")
struct CodecFixtureTests {
    @Test("Byte-for-byte reference read and write", arguments: FixtureSamples.all)
    func goldenJSON(_ sample: FixtureSample) throws {
        let data = try FixtureSamples.data(sample.name)
        let decoded = try Codec.decode(data)
        #expect(decoded == sample.message)
        #expect(try Codec.encode(sample.message) == data)
        #expect(try Codec.encode(decoded) == data)
    }

    @Test("References cover all types and commands")
    func coverage() throws {
        let files = try FileManager.default.contentsOfDirectory(
            atPath: FixtureSamples.directory.path)
        #expect(Set(files) == Set(FixtureSamples.all.map { "\($0.name).json" }))
        #expect(Set(FixtureSamples.all.map(\.message.type)) == Set(Message.MessageType.allCases))
        #expect(Set(FixtureSamples.commands.map(\.kind)) == Set(Command.Kind.allCases))
    }

    @Test("New envelope and body fields are ignored", arguments: FixtureSamples.all)
    func unknownFields(_ sample: FixtureSample) throws {
        let original = try FixtureSamples.data(sample.name)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["futureEnvelopeField"] = ["nested": [1, 2, 3]]
        if var body = object["body"] as? [String: Any] {
            body["futureBodyField"] = ["nested": true]
            object["body"] = body
        } else if var items = object["body"] as? [[String: Any]] {
            for index in items.indices { items[index]["futureItemField"] = "ignored" }
            object["body"] = items
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try Codec.decode(data) == sample.message)
    }

    @Test("Each error code is preserved", arguments: ProtocolError.Code.allCases)
    func errors(_ code: ProtocolError.Code) throws {
        let message = Message.error(
            FixtureSamples.header,
            .init(replyTo: FixtureSamples.replyId, code: code, message: "Error"))
        #expect(try Codec.decode(Codec.encode(message)) == message)
    }

    @Test("Optional duration allows null")
    func nullDuration() throws {
        let data = Data(
            """
            {"v":1,"id":"\(FixtureSamples.id)","type":"recent","body":[
              {"id":"\(FixtureSamples.itemId)","title":"Video.mkv","duration":null,"available":false}
            ]}
            """.utf8)
        #expect(
            try Codec.decode(data)
                == .recent(
                    FixtureSamples.header,
                    [.init(id: FixtureSamples.itemId, title: "Video.mkv", available: false)]))
    }

    @Test("Recent list does not transmit paths, bookmarks, or unknown duration")
    func recentPrivacy() throws {
        let data = try Codec.encode(
            .recent(
                FixtureSamples.header,
                [.init(id: FixtureSamples.itemId, title: "Video.mkv", available: true)]))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(object["body"] as? [[String: Any]])
        #expect(Set(try #require(items.first).keys) == ["id", "title", "available"])
    }

    @Test("JSON without canonical order is also accepted")
    func reorderedJSON() throws {
        let data = Data(
            """
            { "v": 1, "type": "command", "id": "\(FixtureSamples.id)",
              "body": { "seconds": 30, "kind": "seekRelative" } }
            """.utf8)
        #expect(
            try Codec.decode(data) == .command(FixtureSamples.header, .seekRelative(seconds: 30)))
    }
}
