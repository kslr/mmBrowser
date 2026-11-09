import Testing
@testable import MMCore

@Suite("代理字符串解析")
struct ProxyConfigTests {
    @Test func urlForms() throws {
        let a = try ProxyConfig.parse("socks5://user:pa%3Ass@1.2.3.4:1080")
        #expect(a == ProxyConfig(kind: .socks5, host: "1.2.3.4", port: 1080, username: "user", password: "pa:ss"))
        #expect(try ProxyConfig.parse("socks5h://h.example.com:9000").kind == .socks5)
        #expect(try ProxyConfig.parse("http://u:p@proxy.example.com:8080/") ==
                ProxyConfig(kind: .http, host: "proxy.example.com", port: 8080, username: "u", password: "p"))
        #expect(try ProxyConfig.parse("socks5://[2001:db8::1]:1080").host == "2001:db8::1")
    }

    @Test func bareForms() throws {
        #expect(try ProxyConfig.parse("1.2.3.4:8080", defaultKind: .http) == ProxyConfig(kind: .http, host: "1.2.3.4", port: 8080))
        #expect(try ProxyConfig.parse("1.2.3.4:1080:user:p:a:ss") ==
                ProxyConfig(kind: .socks5, host: "1.2.3.4", port: 1080, username: "user", password: "p:a:ss"))
        #expect(try ProxyConfig.parse("user:pass@host.io:1080") ==
                ProxyConfig(kind: .socks5, host: "host.io", port: 1080, username: "user", password: "pass"))
    }

    @Test func roundTripURL() throws {
        let c = ProxyConfig(kind: .http, host: "h", port: 1, username: "a@b", password: "c:d/e")
        #expect(try ProxyConfig.parse(c.urlString) == c)
        #expect(c.displayString == "http://a@b:***@h:1")
    }

    @Test func errors() {
        #expect(throws: ProxyParseError.unsupportedScheme("https")) { try ProxyConfig.parse("https://h:1") }
        #expect(throws: ProxyParseError.invalidPort("70000")) { try ProxyConfig.parse("h:70000") }
        #expect(throws: ProxyParseError.empty) { try ProxyConfig.parse("  ") }
        #expect(throws: (any Error).self) { try ProxyConfig.parse("justahost") }
    }
}
