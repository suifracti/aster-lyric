import Foundation

@main
struct ConversationContract {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-conversation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "lyrics-conversation-contract." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConversationStore(defaults: defaults)
        let provider = TranslationEngineID.codexChatGPT.rawValue
        defaults.set(false, forKey: "ai.conversationVisible.v1." + provider)
        let script = root.appendingPathComponent("codex.py")
        let code = #"""
#!/usr/bin/python3
import json,sys
for raw in sys.stdin:
    v=json.loads(raw); m=v.get('method'); p=v.get('params',{})
    if 'id' not in v: continue
    with open(__file__+'.events','a') as f:f.write(json.dumps({'method':m,'params':p})+'\n')
    if m=='initialize':r={}
    elif m=='account/read':r={'account':{'type':'chatgpt'}}
    elif m=='model/list':r={'data':[{'model':'fixture-model','supportedReasoningEfforts':[{'reasoningEffort':'medium'}]}]}
    elif m in ['thread/start','thread/resume']:
        if m=='thread/resume':assert p['threadId']=='conversation-one'
        if m=='thread/start':assert p['ephemeral'] is False
        r={'thread':{'id':'conversation-one','ephemeral':False},'model':'fixture-model','reasoningEffort':'medium'}
    elif m in ['thread/name/set','thread/archive','thread/unarchive']:r={}
    elif m=='turn/start':r={'turn':{'id':'turn-one'}}
    else:sys.exit(72)
    print(json.dumps({'id':v['id'],'result':r}),flush=True)
    if m=='turn/start':
        # A result from a prior turn is ignored even within the same conversation.
        print(json.dumps({'method':'item/completed','params':{'threadId':'conversation-one','turnId':'old-turn','item':{'type':'agentMessage','text':'stale'}}}),flush=True)
        print(json.dumps({'method':'item/completed','params':{'threadId':'conversation-one','turnId':'turn-one','item':{'type':'agentMessage','phase':'final_answer','text':p['input'][0]['text']}}}),flush=True)
        print(json.dumps({'method':'turn/completed','params':{'threadId':'conversation-one','turn':{'id':'turn-one','status':'completed'}}}),flush=True)
"""#
        try code.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for title in ["song-A", "song-B"] {
            let client = try CodexAppServerClient(executable: script.path, cwd: root, timeout: 8,
                diagnosticSink: { _ in }, conversationStore: store)
            defer { client.stop() }
            try client.initialize()
            try client.ensureAuthenticated()
            let result = try client.translate(prompt: .init(system: "fixture", user: title, promptHash: title),
                model: "fixture-model", reasoningEffort: "medium", outputSchema: ["type": "object"])
            precondition(result.text.hasSuffix(title), "results must remain turn-specific")
        }
        let rows = try String(contentsOfFile: script.path + ".events", encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let methods = rows.compactMap { $0["method"] as? String }
        precondition(methods.filter { $0 == "thread/start" }.count == 1)
        precondition(methods.filter { $0 == "thread/resume" }.count == 1)
        precondition(methods.filter { $0 == "thread/unarchive" }.count == 1)
        precondition(methods.filter { $0 == "thread/archive" }.count == 2)
        precondition(store.threadID(for: provider) == "conversation-one" && store.isArchived(for: provider))
        precondition(store.threadID(for: TranslationEngineID.grokBuild.rawValue) == nil)
        let reopened = AIConversationStore(defaults: defaults)
        precondition(reopened.threadID(for: provider) == "conversation-one")
        reopened.startNew(for: provider)
        precondition(reopened.threadID(for: provider) == nil)
        print("PASS: one durable conversation, resume/hide/reopen, explicit new conversation and turn isolation")
    }
}
