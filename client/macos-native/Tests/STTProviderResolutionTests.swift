import XCTest
@testable import VibeCodingPlusNative

final class STTProviderResolutionTests: XCTestCase {

    func testConfigProviderOverridesKeyInference() {
        var config = ServerConfig()
        config.sttProvider = "openai"
        config.openaiApiKey = "sk-test"
        config.qwenAsrApiKey = "qwen-test"
        let service = STTService(config: config)
        XCTAssertEqual(service.resolveProvider(), .openai)
    }

    func testKeyInferencePrefersWhisperWhenConfigured() {
        var config = ServerConfig()
        config.sttProvider = ""
        config.whisperCppModelPath = "/tmp/model.bin"
        config.openaiApiKey = "sk-test"
        let service = STTService(config: config)
        XCTAssertEqual(service.resolveProvider(), .whisperCpp)
    }
}
