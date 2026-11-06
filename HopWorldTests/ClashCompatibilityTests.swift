import XCTest

final class ClashCompatibilityTests: XCTestCase {
    func testIndentlessListNestedWebSocketHostAndComments() throws {
        let text = """
        proxies:
        - name: 'Japan: #1'
          type: vmess
          server: example.com
          port: 443 # standard TLS
          uuid: 11111111-1111-4111-8111-111111111111
          network: ws
          tls: true
          ws-opts:
            path: '/socket?a=1#fragment'
            headers:
              Host: cdn.example.com
          alpn:
            - h2
            - http/1.1
        proxy-groups:
          - name: ignored
        """
        let node = try XCTUnwrap(ClashYAMLParser.parse(text).validNodes.first)
        XCTAssertEqual(node.name, "Japan: #1")
        XCTAssertEqual(node.host, "cdn.example.com")
        XCTAssertEqual(node.path, "/socket?a=1#fragment")
        XCTAssertEqual(node.alpn, "h2,http/1.1")
        XCTAssertEqual(node.security, .tls)
    }

    func testNestedInlineMapsAndQuotedCommas() throws {
        let text = #"""
        proxies:
          - {name: "Node, 1", type: vless, server: example.com, port: 443, uuid: 11111111-1111-4111-8111-111111111111, network: grpc, grpc-opts: {grpc-service-name: "svc,one"}, reality-opts: {public-key: "public-key", short-id: "00ab"}, alpn: [h2, http/1.1]}
        """#
        let node = try XCTUnwrap(ClashYAMLParser.parse(text).validNodes.first)
        XCTAssertEqual(node.name, "Node, 1")
        XCTAssertEqual(node.serviceName, "svc,one")
        XCTAssertEqual(node.publicKey, "public-key")
        XCTAssertEqual(node.shortID, "00ab")
        XCTAssertEqual(node.security, .reality)
        XCTAssertEqual(node.alpn, "h2,http/1.1")
    }

    func testInlineProxyArrayEscapesAndCaseInsensitiveHost() throws {
        let text = #"""
        proxies: [{name: "Node \"A\"", type: trojan, server: example.com, port: 443, password: 'a,b:#it''s', network: ws, ws-opts: {path: "/ws", headers: {hOsT: "edge.example.com"}}}]
        """#
        let node = try XCTUnwrap(ClashYAMLParser.parse(text).validNodes.first)
        XCTAssertEqual(node.name, "Node \"A\"")
        XCTAssertEqual(node.password, "a,b:#it's")
        XCTAssertEqual(node.host, "edge.example.com")
    }

    func testRealityKeyAliasesAndBlockMapsPreservePublicKey() throws {
        for field in ["public-key", "publicKey", "public_key", "password"] {
            let text = """
            proxies:
              - name: Reality
                type: vless
                server: example.com
                port: 443
                uuid: 11111111-1111-4111-8111-111111111111
                reality-opts:
                  \(field): fixture-key
                  shortId: 00ab
            """
            let node = try XCTUnwrap(ClashYAMLParser.parse(text).validNodes.first)
            XCTAssertEqual(node.publicKey, "fixture-key", field)
            XCTAssertEqual(node.shortID, "00ab", field)
            XCTAssertEqual(node.security, .reality, field)
            XCTAssertTrue(NodeConfigChecker.validate(node).0, field)
        }
        let text = "proxies: [{name: Reality, type: vless, server: example.com, port: 443, uuid: 11111111-1111-4111-8111-111111111111, publicKey: fixture-key}]"
        let node = try XCTUnwrap(ClashYAMLParser.parse(text).validNodes.first)
        XCTAssertEqual(node.security, .reality)
        XCTAssertEqual(node.publicKey, "fixture-key")
    }

    func testVMessAndTrojanRealityOptsKeepPublicKey() throws {
        for type in ["vmess", "trojan"] {
            let credential = type == "vmess"
                ? "uuid: 11111111-1111-4111-8111-111111111111"
                : "password: secret"
            let text = """
            proxies:
              - name: Reality
                type: \(type)
                server: example.com
                port: 443
                \(credential)
                reality-opts:
                  public-key: fixture-key
                  short-id: 00ab
            """
            let node = try XCTUnwrap(ClashYAMLParser.parse(text).validNodes.first)
            XCTAssertEqual(node.security, .reality, type)
            XCTAssertEqual(node.publicKey, "fixture-key", type)
            XCTAssertEqual(node.shortID, "00ab", type)
            XCTAssertTrue(NodeConfigChecker.validate(node).0, type)
            XCTAssertEqual(node.spiderX, nil, type)
        }
    }

    func testRealitySpiderXSurvivesYAML() throws {
        for type in ["vless", "vmess", "trojan"] {
            let credential = type == "trojan"
                ? "password: secret"
                : "uuid: 11111111-1111-4111-8111-111111111111"
            let text = """
            proxies:
              - name: Reality
                type: \(type)
                server: example.com
                port: 443
                \(credential)
                network: xhttp
                xhttp-opts:
                  path: /xh
                  host: cdn.example
                reality-opts:
                  public-key: fixture-key
                  short-id: 00ab
                  spider-x: /crawl
            """
            let node = try XCTUnwrap(ClashYAMLParser.parse(text).validNodes.first)
            XCTAssertEqual(node.transport, .xhttp, type)
            XCTAssertEqual(node.path, "/xh", type)
            XCTAssertEqual(node.host, "cdn.example", type)
            XCTAssertEqual(node.security, .reality, type)
            XCTAssertEqual(node.spiderX, "/crawl", type)
            XCTAssertTrue(NodeConfigChecker.validate(node).0, type)
        }
        let alias = "proxies: [{name: Reality, type: vless, server: example.com, port: 443, uuid: 11111111-1111-4111-8111-111111111111, network: splithttp, reality-opts: {public-key: fixture-key, spx: /alias}}]"
        let node = try XCTUnwrap(ClashYAMLParser.parse(alias).validNodes.first)
        XCTAssertEqual(node.transport, .xhttp)
        XCTAssertEqual(node.spiderX, "/alias")
    }

    func testRealityKeySkipsEmptyFieldsWithoutBypassingMissingKeyValidation() throws {
        let prefix = "proxies: [{name: Reality, type: vless, server: example.com, port: 443, uuid: 11111111-1111-4111-8111-111111111111, reality-opts: {"
        for (fields, expected) in [("public-key: canonical, publicKey: alias", "canonical"),
                                   ("public-key: '', publicKey: alias", "alias"),
                                   ("public-key: '  ', public_key: alias", "alias")] {
            let node = try XCTUnwrap(ClashYAMLParser.parse(prefix + fields + ", short-id: ''}}]").validNodes.first)
            XCTAssertEqual(node.publicKey, expected)
            XCTAssertEqual(node.shortID, "")
        }
        let missing = try XCTUnwrap(ClashYAMLParser.parse(prefix + "public-key: '  ', short-id: ''}}]").validNodes.first)
        XCTAssertEqual(missing.security, .reality)
        XCTAssertNil(missing.publicKey)
        XCTAssertEqual(NodeConfigChecker.validate(missing).1, "REALITY 缺少 publicKey")
    }

    func testUnknownTransportMissingCredentialsAndInvalidPortsAreNotValidNodes() throws {
        for fields in ["network: unsupported, password: p", "network: tcp", "password: p, port: 99999"] {
            let text = "proxies: [{name: n, type: trojan, server: example.com, port: 443, \(fields)}]"
            XCTAssertThrowsError(try ClashYAMLParser.parse(text))
        }
    }

    func testAliasesAndMalformedNestedMapsFailInsteadOfLosingParameters() throws {
        for text in ["proxies:\n  - *node", "proxies:\n  - {name: n, type: trojan, server: example.com, port: 443, password: p, ws-opts: {path: /ws}"] {
            XCTAssertThrowsError(try ClashYAMLParser.parse(text))
        }
    }
}
