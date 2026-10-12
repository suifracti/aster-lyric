import Foundation
func expect(_ good: Bool, _ message: String) { if !good { print("FAIL: " + message); exit(1) } }
actor ModelGate {
 var requests: [CheckedContinuation<[TranslationModelDescriptor], Error>] = []
 func load(_ c: AITranslationConfiguration) async throws -> [TranslationModelDescriptor] {
  try await withCheckedThrowingContinuation { requests.append($0) }
 }
 func count() -> Int { requests.count }
 func finish(_ n: Int, _ models: [TranslationModelDescriptor]) { requests[n].resume(returning: models) }
 func fail(_ n: Int) { requests[n].resume(throwing: AITranslationError.unauthorized) }
}
@main struct Contract {
 @MainActor static func main() async throws {
  let suite = "com.lyricsq.test.provider-model." + UUID().uuidString
  let defaults = UserDefaults(suiteName:suite)!; defer { defaults.removePersistentDomain(forName:suite) }
  let gate = ModelGate()
  let loader: TranslationModelSettingsStore.Loader = { c in try await gate.load(c) }
  var c = AITranslationConfiguration(model:"codex-manual", engineID:TranslationEngineID.codexChatGPT.rawValue, codexReasoningEffort:"medium")
  let store = TranslationModelSettingsStore(defaults:defaults, configuration:c, loader:loader)
  expect(await gate.count() == 0, "opening settings must not fetch a directory")
  c = store.selectProvider(from:c, to:TranslationEngineID.grokBuild.rawValue)
  expect(c.model.isEmpty && c.grokReasoningEffort.isEmpty, "first provider selection must not reuse Codex model/effort")
  c.model="grok-manual";c.grokReasoningEffort="high";store.remember(c)
  c = store.selectProvider(from:c, to:TranslationEngineID.geminiCLI.rawValue)
  expect(c.model.isEmpty, "Gemini must not show Grok model")
  c.model="gemini-manual";c.geminiThinkingBudget=123;store.remember(c)
  c = store.selectProvider(from:c, to:TranslationEngineID.codexChatGPT.rawValue)
  expect(c.model=="codex-manual" && c.codexReasoningEffort=="medium", "Codex model/native effort restore")
  let reopened = TranslationModelSettingsStore(defaults:defaults,configuration:c,loader:loader)
  var g = reopened.selectProvider(from:c,to:TranslationEngineID.grokBuild.rawValue)
  expect(g.model=="grok-manual" && g.grokReasoningEffort=="high", "provider model/native setting persist across reopen")
  let j = reopened.selectProvider(from:g,to:TranslationEngineID.geminiCLI.rawValue)
  expect(j.model=="gemini-manual" && j.geminiThinkingBudget==123, "Gemini native budget persists independently")
  var d = reopened.selectProvider(from:j,to:TranslationEngineID.deepSeekAPI.rawValue)
  expect(d.model.isEmpty, "DeepSeek first selection cannot inherit Gemini model")
  d.model="deepseek-manual";d.deepSeekThinkingMode="enabled";d.deepSeekReasoningEffort="low";reopened.remember(d)
  let dc = reopened.selectProvider(from:d,to:TranslationEngineID.codexChatGPT.rawValue)
  let dr = reopened.selectProvider(from:dc,to:TranslationEngineID.deepSeekAPI.rawValue)
  expect(dr.model=="deepseek-manual" && dr.deepSeekThinkingMode=="enabled" && dr.deepSeekReasoningEffort=="low", "DeepSeek native thinking remains separate from Codex medium")
  var one=reopened.selectProvider(from:dr,to:TranslationEngineID.openAICompatible.rawValue)
  one.baseURL="https://legacy-one.invalid/v1";one.model="legacy-model";reopened.remember(one)
  var two=reopened.selectAPIEndpoint(from:one,to:"https://new-two.invalid/v1")
  expect(two.model.isEmpty && two.apiCredentialAccount != "default","new API service cannot inherit old model or key account")
  two.model="second-model";reopened.remember(two)
  let firstAgain=reopened.selectAPIEndpoint(from:two,to:one.baseURL)
  expect(firstAgain.model=="legacy-model" && firstAgain.apiCredentialAccount=="default","legacy key reference preserved without copying credentials")
  let secondAgain=reopened.selectAPIEndpoint(from:firstAgain,to:two.baseURL)
  expect(secondAgain.model=="second-model" && secondAgain.apiCredentialAccount==two.apiCredentialAccount,"each custom API endpoint retains independent configuration")
  let reopenedAPI=TranslationModelSettingsStore(defaults:defaults,configuration:secondAgain,loader:loader)
  expect(reopenedAPI.savedAPIEndpoints().contains(one.baseURL),"saved API services survive reopen")
  let legacyGemini=reopenedAPI.selectProvider(from:secondAgain,to:TranslationEngineID.geminiCLI.rawValue)
  expect(legacyGemini.model=="gemini-manual" && legacyGemini.geminiThinkingBudget==123,"hidden Gemini backend retained without silent migration to agy")
  store.refresh(c)
  for _ in 0..<1000 { if await gate.count()>=1 { break }; await Task.yield() }
  expect(await gate.count()==1,"explicit refresh starts exactly one directory request")
  g=store.selectProvider(from:c,to:TranslationEngineID.grokBuild.rawValue);store.refresh(g)
  for _ in 0..<1000 { if await gate.count()>=2 { break }; await Task.yield() }
  expect(await gate.count()==2,"second provider request starts")
  await gate.finish(0,[.init(id:"old-codex")]);await gate.finish(1,[.init(id:"grok-discovered",source:"offline-fixture")])
  for _ in 0..<1000 { if store.models.first?.id=="grok-discovered" { break }; await Task.yield() }
  expect(store.models.map(\.id)==["grok-discovered"],"late Codex directory cannot overwrite Grok")
  expect(store.selectionKind(model:"grok-manual")=="ID 未在当前目录", "unknown ID is not presented as discovered or claimed to have been manually typed")
  expect(store.selectionKind(model:"grok-discovered")=="已发现模型", "selected known ID appears as discovered")
  store.refresh(g)
  for _ in 0..<1000 { if await gate.count()>=3 { break }; await Task.yield() }
  expect(store.status == .loading, "loading state is visible, prior same-provider cache retained")
  await gate.fail(2)
  for _ in 0..<1000 { if store.status == .unauthorized { break }; await Task.yield() }
  expect(store.status == .unauthorized && store.models.map(\.id)==["grok-discovered"], "failure is honest and retains same-provider cache")
  c=store.selectProvider(from:g,to:TranslationEngineID.codexChatGPT.rawValue)
  expect(store.models.isEmpty,"rejected late directory was not persisted under old provider")
  g=store.selectProvider(from:c,to:TranslationEngineID.grokBuild.rawValue)
  expect(store.models.map(\.id)==["grok-discovered"],"provider directory cache restores immediately")
  let cacheReopened=TranslationModelSettingsStore(defaults:defaults,configuration:g,loader:loader)
  expect(cacheReopened.models.map(\.id)==["grok-discovered"], "discovered directory survives reopening under correct provider")
  store.refresh(g)
  for _ in 0..<1000 { if await gate.count()>=4 { break }; await Task.yield() }
  await gate.finish(3,[])
  for _ in 0..<1000 { if store.status == .empty { break }; await Task.yield() }
  expect(store.status == .empty && store.models.isEmpty,"successful empty directory distinguished from failure")
  var api=store.selectProvider(from:g,to:TranslationEngineID.openAICompatible.rawValue)
  api.baseURL="https://fixture-one.invalid/v1";api.model="api-manual";store.remember(api);store.refresh(api)
  for _ in 0..<1000 { if await gate.count()>=5 { break }; await Task.yield() }
  api.baseURL="https://fixture-two.invalid/v1";store.remember(api)
  await gate.finish(4,[.init(id:"wrong-endpoint")]);for _ in 0..<100 { await Task.yield() }
  expect(store.models.isEmpty,"endpoint change rejects old directory")
  let old=store.selectProvider(from:api,to:TranslationEngineID.codexChatGPT.rawValue)
  store.refresh(old)
  for _ in 0..<1000 { if await gate.count()>=6 { break }; await Task.yield() }
  _=store.selectProvider(from:old,to:TranslationEngineID.geminiCLI.rawValue)
  store.remember(old) // A→B→A, same identity but different generation.
  await gate.finish(5,[.init(id:"late-roundtrip")]);for _ in 0..<100 { await Task.yield() }
  expect(store.models.isEmpty,"A-B-A rejects late directory despite matching provider identity")
  print("PASS: provider-owned models/native settings, reopen, honest states, cache and late directory boundaries")
 }
}
