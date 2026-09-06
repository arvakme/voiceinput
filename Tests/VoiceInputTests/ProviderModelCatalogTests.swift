import Foundation
import Testing
@testable import VoiceInput

struct ProviderModelCatalogTests {
    @Test func compatibleCatalogPreservesFriendlyNames() throws {
        let rows = try ModelCatalog.parseCompatible(["data": [["id": "vendor/model", "name": "Readable model"]]])
        #expect(rows.first?.modelID == "vendor/model")
        #expect(rows.first?.displayName == "Readable model")
    }
    @Test func sonioxCatalogSeparatesRealtimeAndBatch() throws {
        let data: [String: Any] = ["models": [["id": "stt-rt-v5"], ["id": "stt-async-v5"], ["id": "tts-rt-v1"]]]
        #expect(try ModelCatalog.parseSoniox(data, realtime: true).map(\.modelID) == ["stt-rt-v5"])
        #expect(try ModelCatalog.parseSoniox(data, realtime: false).map(\.modelID) == ["stt-async-v5"])
    }
    @Test func geminiCatalogOnlyOffersLiveModels() throws {
        let data: [String: Any] = ["models": [
            ["name": "models/gemini-live", "displayName": "Live audio"],
            ["name": "models/speech-new", "supportedGenerationMethods": ["bidiGenerateContent"]],
            ["name": "models/embedding", "supportedGenerationMethods": ["embedContent"]]
        ]]
        #expect(try ModelCatalog.parseGemini(data).map(\.modelID) == ["gemini-live", "speech-new"])
    }
    @Test func ollamaCatalogAndSameOriginURLBuilding() throws {
        #expect(try ModelCatalog.parseOllama(["models": [["name": "qwen:latest"]]]).first?.modelID == "qwen:latest")
        #expect(try ModelCatalog.modelsURL("http://127.0.0.1:11434/v1/").absoluteString == "http://127.0.0.1:11434/v1/models")
        #expect(throws: (any Error).self) { try ModelCatalog.modelsURL("file:///tmp/models") }
    }
    @Test func cacheIsSeparatedByAccountWithoutStoringItsKeyInTheIndex() {
        let first = ModelCatalog.Configuration(kind: .cursor, apiKey: "fake-key-one")
        let second = ModelCatalog.Configuration(kind: .cursor, apiKey: "fake-key-two")
        #expect(first.cacheKey != second.cacheKey)
        #expect(!first.cacheKey.contains("fake-key-one"))
    }
    @Test @MainActor func cursorFastParameterPersistsSeparatelyFromItsModelID() throws {
        let name = "voiceinput-model-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PolishConnectionStore(defaults: defaults)
        store.cursorModelParams = [.init(id: "fast", value: "true")]
        #expect(PolishConnectionStore(defaults: defaults).cursorModelParams == [.init(id: "fast", value: "true")])
    }
    @Test func fastSearchMatchesEnabledVariantAndParameterQueriesRemainAvailable() {
        let fast = CatalogModel(modelID: "composer-2.5", displayName: "Composer 2.5 · Fast",
            parameters: [.init(id: "fast", value: "true")])
        let standard = CatalogModel(modelID: "composer-2.5", displayName: "Composer 2.5 · Standard",
            parameters: [.init(id: "fast", value: "false")])
        #expect(ModelCatalogSearch.matches(fast, query: "composer fast"))
        #expect(!ModelCatalogSearch.matches(standard, query: "fast"))
        #expect(ModelCatalogSearch.matches(standard, query: "fast=false"))
        #expect(ModelCatalogSearch.matches(standard, query: "fast false"))
        #expect(ModelCatalogSearch.matches(standard, query: "standard"))
    }

}
