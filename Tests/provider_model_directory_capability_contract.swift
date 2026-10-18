import Foundation
@main struct CapabilityContract {
 static func main() {
  let codex = CodexAppServerTranslationService(executableCandidates: ["/usr/bin/true"])
  if !codex.metadata.supportsModelDirectory { print("FAIL: installed Codex must expose model directory selection"); exit(1) }
  let grok = GrokBuildTranslationService(executableCandidates: ["/usr/bin/true"])
  if !grok.metadata.supportsModelDirectory { print("FAIL: installed Grok must expose model directory selection"); exit(1) }
  let cache = #"{"models":{"grok-4.7":{"info":{"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"xhigh"},{"value":"high"},{"value":"medium"},{"value":"low"}]}},"grok-4.5":{"info":{"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"high"},{"value":"medium"},{"value":"low"}]}},"grok-no-reasoning":{"info":{"supports_reasoning_effort":false}}}}"#
  let directory = try! GrokBuildTranslationService.parseModelDirectory(
    Data("grok-4.7 Model 4.7\ngrok-4.5 Model 4.5\ngrok-no-reasoning Model\ngrok-unlisted Model\n".utf8),
    modelCacheData: Data(cache.utf8))
  if directory.first(where: { $0.id == "grok-4.7" })?.reasoningEfforts != ["xhigh", "high", "medium", "low"] {
    print("FAIL: Grok reasoning values must come from the selected model's local metadata"); exit(1)
  }
  if directory.first(where: { $0.id == "grok-4.5" })?.reasoningEfforts != ["high", "medium", "low"] {
    print("FAIL: Grok must not add xhigh where the model metadata omits it"); exit(1)
  }
  if directory.first(where: { $0.id == "grok-no-reasoning" })?.reasoningEfforts != [] {
    print("FAIL: explicit no-reasoning metadata must remain distinct from unknown"); exit(1)
  }
  if directory.first(where: { $0.id == "grok-unlisted" })?.reasoningEfforts != nil {
    print("FAIL: absent local model metadata must remain unknown"); exit(1)
  }
  print("PASS: installed CLI model directory capabilities")
 }
}
