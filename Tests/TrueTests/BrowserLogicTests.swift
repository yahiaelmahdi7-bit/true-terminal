import Testing
import Foundation
import CoreGraphics
@testable import True
import TrueRemoteClient

@Suite("Browser logic")
struct BrowserLogicTests {
    @Test func cdpEncodeIsStableAndRoundTrips() {
        let s = CDPMessage.encode(id: 7, method: "Page.navigate", params: ["url": "http://x"], sessionId: "S1")
        #expect(s == #"{"id":7,"method":"Page.navigate","params":{"url":"http:\/\/x"},"sessionId":"S1"}"#)
        let o = try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        #expect(o["id"] as? Int == 7)
        #expect(CDPMessage.encode(id: 1, method: "Page.enable") == #"{"id":1,"method":"Page.enable"}"#)
    }

    @Test func cdpDecodesResponsesEventsAndErrors() {
        #expect(CDPMessage.decode(#"{"id":3,"result":{"frameId":"F"}}"#) == .response(id: 3, result: ["frameId": "F"], error: nil))
        #expect(CDPMessage.decode(#"{"id":4,"error":{"code":-32000,"message":"No target"}}"#) == .response(id: 4, result: nil, error: "No target"))
        #expect(CDPMessage.decode(#"{"method":"Page.screencastFrame","params":{"sessionId":9},"sessionId":"S1"}"#)
                == .event(method: "Page.screencastFrame", params: ["sessionId": 9], sessionId: "S1"))
        #expect(CDPMessage.decode("not json") == nil)
        #expect(CDPMessage.decode(#"{"foo":1}"#) == nil)
    }

    @Test func frameWireRoundTrip() {
        let jpeg = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
        let d = BrowserWire.encodeFrame(header: ["t": "frame", "w": 390, "h": 800, "seq": 5], jpeg: jpeg)
        let back = BrowserWire.decodeFrame(d)
        #expect(back?.jpeg == jpeg)
        #expect(back?.header["w"] as? Int == 390)
        #expect(BrowserWire.decodeFrame(Data([0, 0, 0, 99, 1])) == nil)
        #expect(BrowserWire.decodeFrame(Data([1])) == nil)
    }

    @Test func touchMapsToPageCoordsAtAnyScale() {
        let view = CGSize(width: 390, height: 780)
        // No zoom: centre of the view is the centre of the page, at every viewport size/scale.
        for vp in [CGSize(width: 390, height: 780), CGSize(width: 780, height: 1560), CGSize(width: 1000, height: 2000)] {
            let n = BrowserInputMapper.normalized(point: CGPoint(x: 195, y: 390), viewSize: view)
            #expect(BrowserInputMapper.pagePoint(nx: n.x, ny: n.y, viewport: vp) == CGPoint(x: vp.width / 2, y: vp.height / 2))
        }
        // Corner taps clamp inside the page.
        let c = BrowserInputMapper.normalized(point: CGPoint(x: 999, y: -5), viewSize: view)
        #expect(c == CGPoint(x: 1, y: 0))
        // 2× zoom about the centre: the view's top-left quarter point (97.5, 195) hits the page's (146.25, 292.5)
        let z = BrowserInputMapper.normalized(point: CGPoint(x: 97.5, y: 195), viewSize: view, zoom: 2)
        #expect(abs(z.x - 0.375) < 1e-9 && abs(z.y - 0.375) < 1e-9)
        // Panned view: pan shifts which page point sits under the finger.
        let p = BrowserInputMapper.normalized(point: CGPoint(x: 195, y: 390), viewSize: view, zoom: 2, pan: CGPoint(x: 100, y: 0))
        #expect(abs(p.x - 145.0 / 390.0) < 1e-9 && abs(p.y - 0.5) < 1e-9)
    }

    @Test func wheelFollowsFingerOppositeAndScales() {
        let d = BrowserInputMapper.wheelDelta(fingerDelta: CGPoint(x: 0, y: -100), viewSize: CGSize(width: 390, height: 780),
                                              viewport: CGSize(width: 390, height: 780))
        #expect(d == CGPoint(x: 0, y: 100))
        let z = BrowserInputMapper.wheelDelta(fingerDelta: CGPoint(x: 0, y: -100), viewSize: CGSize(width: 390, height: 780),
                                              viewport: CGSize(width: 780, height: 1560), zoom: 2)
        #expect(z.y == 100)
    }

    @Test func commandsParseAndRejectJunk() {
        #expect(BrowserCommand.parse(#"{"t":"tap","x":0.5,"y":0.25}"#) == .tap(x: 0.5, y: 0.25))
        #expect(BrowserCommand.parse(#"{"t":"viewport","w":390,"h":780,"scale":2}"#) == .viewport(w: 390, h: 780, scale: 2))
        #expect(BrowserCommand.parse(#"{"t":"viewport","w":10,"h":780}"#) == nil)
        #expect(BrowserCommand.parse(#"{"t":"viewport","w":390,"h":780,"scale":9}"#) == .viewport(w: 390, h: 780, scale: 3))
        #expect(BrowserCommand.parse(#"{"t":"scroll","x":0.5,"y":0.5,"dy":120}"#) == .scroll(x: 0.5, y: 0.5, dx: 0, dy: 120))
        #expect(BrowserCommand.parse(#"{"t":"tab.close","id":"A"}"#) == .closeTab("A"))
        #expect(BrowserCommand.parse(#"{"t":"nope"}"#) == nil)
        #expect(BrowserCommand.parse("x") == nil)
    }

    @Test func urlBarNormalization() {
        #expect(BrowserURL.normalize("localhost:3000") == "http://localhost:3000")
        #expect(BrowserURL.normalize("127.0.0.1:8765/a") == "http://127.0.0.1:8765/a")
        #expect(BrowserURL.normalize("example.com") == "https://example.com")
        #expect(BrowserURL.normalize("https://a.b/c") == "https://a.b/c")
        #expect(BrowserURL.normalize("swift concurrency")?.hasPrefix("https://www.google.com/search?q=swift%20concurrency") == true)
        #expect(BrowserURL.normalize("javascript:alert(1)") == nil)
        #expect(BrowserURL.normalize("file:///etc/passwd") == nil)
        #expect(BrowserURL.normalize("  ") == nil)
    }

    @Test func slowSocketDropsFramesNotMemory() {
        let f = LatestFrame()
        for i in 0..<5 { f.put(Data([UInt8(i)])) }
        #expect(f.take() == Data([4]))      // only the newest survives
        #expect(f.dropped == 4)
        #expect(f.take() == nil)
        f.put(Data([9]))
        #expect(f.take() == Data([9]))
        #expect(f.dropped == 4 && f.delivered == 2)
    }

    @Test func keySpecs() {
        #expect(BrowserKeys.spec("Enter")?.vk == 13)
        #expect(BrowserKeys.spec("ArrowDown")?.code == "ArrowDown")
        #expect(BrowserKeys.spec("F13") == nil)
    }
}
