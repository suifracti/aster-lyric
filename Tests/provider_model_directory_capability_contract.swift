import Foundation
@main struct CapabilityContract {
 static func main() {
  let codex = CodexAppServerTranslationService(executableCandidates: ["/usr/bin/true"])
  if !codex.metadata.supportsModelDirectory { print("FAIL: installed Codex must expose model directory selection"); exit(1) }
  let grok = GrokBuildTranslationService(executableCandidates: ["/usr/bin/true"])
  if !grok.metadata.supportsModelDirectory { print("FAIL: installed Grok must expose model directory selection"); exit(1) }
  print("PASS: installed CLI model directory capabilities")
 }
}
