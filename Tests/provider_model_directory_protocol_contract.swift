import Foundation
func check(_ b: Bool, _ m: String) { if !b { print("FAIL: " + m); exit(1) } }
struct DirectoryHTTPFixture: AIHTTPClient {
 let body: String
 func data(for r: URLRequest) async throws -> (Data, URLResponse) {
  check(r.httpMethod=="GET" && r.httpBody==nil,"directory only GET, never translation body")
  check(r.url!.absoluteString=="https://example.invalid/v1/models","only models endpoint")
  return (Data(body.utf8), HTTPURLResponse(url:r.url!, statusCode:200,httpVersion:nil,headerFields:nil)!)
 }
}
@main struct ProtocolContract {
 static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-directory-contract-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
  defer { try? FileManager.default.removeItem(at:root) }
  let agyText="gemini-fixture\tGemini fixture (Medium)\nclaude-fixture\tClaude fixture\n"
  let agyModels=try AntigravityCLITranslationService.parseModels(Data(agyText.utf8))
  check(agyModels.map(\.id)==["gemini-fixture","claude-fixture"],"agy uses real ID/tab/name protocol")
  check(agyModels.first?.displayName=="Gemini fixture (Medium)" && agyModels.first?.reasoningEfforts==nil,"label Medium is not fabricated capability metadata")
  do { _=try AntigravityCLITranslationService.parseModels(Data("unexpected format".utf8));check(false,"malformed directory is not empty success") } catch AITranslationError.invalidResponse {}
  let codex=root.appendingPathComponent("codex-fixture.py")
  let code="""
#!/usr/bin/python3
import json,sys
for text in sys.stdin:
 v=json.loads(text);m=v.get('method')
 if 'id' not in v: continue
 with open(__file__+'.events','a') as f: f.write(m+'\\n')
 if m=='initialize': r={}
 elif m=='account/read':
  assert v['params']['refreshToken'] is False
  r={'account':{'type':'chatgpt'}}
 elif m=='model/list':
  assert v['params']['includeHidden'] is False
  if 'cursor' not in v['params']:r={'data':[{'model':'codex-fixture-1','displayName':'Fixture one','supportedReasoningEfforts':[{'reasoningEffort':'low'},{'reasoningEffort':'medium'}]}],'nextCursor':'page2'}
  else:r={'data':[{'model':'codex-fixture-2'}],'nextCursor':None}
 else: sys.exit(72)
 print(json.dumps({'id':v['id'],'result':r}),flush=True)
"""
  try code.write(to:codex,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:codex.path)
  let cm=try await CodexAppServerTranslationService(executableCandidates:[codex.path]).listModels(timeout:3)
  check(cm.map(\.id)==["codex-fixture-1","codex-fixture-2"],"actual model-list pagination and selection IDs")
  check(cm.first?.reasoningEfforts==["low","medium"],"actual model/list capability fields retained, not guessed")
  let events=try String(contentsOfFile:codex.path+".events",encoding:.utf8).split(separator:"\n").map(String.init)
  check(events==["initialize","account/read","model/list","model/list"],"no thread, turn, prompt or tools request")
  let grok=root.appendingPathComponent("grok-fixture.py")
  let gcode="""
#!/usr/bin/python3
import sys
assert sys.argv[1:]==['--no-subagents','models']
print('Models\\ngrok-fixture-1  Model one\\ngrok-fixture-2  Model two')
"""
  try gcode.write(to:grok,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:grok.path)
  let gm=try await GrokBuildTranslationService(executableCandidates:[grok.path]).listModels(timeout:3)
  check(gm.map(\.id)==["grok-fixture-1","grok-fixture-2"],"Grok only models arguments and directory IDs")
  for bad in ["", "not a model directory"] {
   do { _=try GrokBuildTranslationService.parseModelDirectory(Data(bad.utf8));check(false,"invalid Grok output must fail, not show zero models") } catch { }
  }
  let c=AITranslationConfiguration(baseURL:"https://example.invalid/v1")
  let empty=try await OpenAICompatibleClient(httpClient:DirectoryHTTPFixture(body:"{\"data\":[]}")).listModels(configuration:c,apiKey:"self-written-fixture-key")
  check(empty.isEmpty,"explicit valid empty API directory is a real empty state")
  for bad in ["{}", "{\"data\":[{}]}"] {
   do { _=try await OpenAICompatibleClient(httpClient:DirectoryHTTPFixture(body:bad)).listModels(configuration:c,apiKey:"self-written-fixture-key");check(false,"malformed API directory must fail") } catch { }
  }
  // Actual owned process ignores SIGTERM. Cancellation must reap it before the 20s timeout.
  let slow=root.appendingPathComponent("slow-grok.py")
  let slowCode="""
#!/usr/bin/python3
import sys,os,signal,time
assert sys.argv[1:]==['--no-subagents','models']
signal.signal(signal.SIGTERM,signal.SIG_IGN)
with open(__file__+'.pid','w') as f:f.write(str(os.getpid()))
time.sleep(60)
"""
  try slowCode.write(to:slow,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:slow.path)
  let task=Task { try await GrokBuildTranslationService(executableCandidates:[slow.path]).listModels(timeout:20) }
  for _ in 0..<100 { if FileManager.default.fileExists(atPath:slow.path+".pid") { break }; try await Task.sleep(nanoseconds:10_000_000) }
  let pid=Int32(try String(contentsOfFile:slow.path+".pid",encoding:.utf8))!
  let began=Date();task.cancel()
  do { _=try await task.value;check(false,"cancelled model query cannot succeed") } catch AITranslationError.cancelled {} catch { check(false,"cancellation must retain cancelled status") }
  check(Date().timeIntervalSince(began)<3,"owned directory process reaped promptly despite ignored SIGTERM")
  check(kill(pid,0) != 0,"owned directory process is gone")
  print("PASS: CLI directory-only calls, pagination, HTTP shape, honest malformed/empty states and owned-process cancellation")
 }
}
