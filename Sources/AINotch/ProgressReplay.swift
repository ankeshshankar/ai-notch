import AppKit
import ReviewCore
import SwiftUI

/// Dev only: `--progress-replay <review folder> <session transcript>` shows the progress view of an existing run, as
/// it stood when its files were last written. It only reads (the folder and the session files are never changed) and
/// never starts, sends or posts anything. The reading runs off the main thread.
enum ProgressReplay {
    @MainActor
    final class Model: ObservableObject {
        @Published var progress: ReviewProgress?
        @Published var at: Double = 0
    }

    @MainActor
    static func run(_ args: [String]) {
        guard let i = args.firstIndex(of: "--progress-replay"), i + 2 < args.count else {
            FileHandle.standardError.write(Data("--progress-replay needs a review folder and a session transcript\n".utf8))
            exit(2)
        }
        let folder = URL(fileURLWithPath: args[i + 1]), transcript = URL(fileURLWithPath: args[i + 2])
        let model = Model()
        DispatchQueue.global(qos: .utility).async {
            // "Now" is when the transcript was last written, so the graph shows the run's last minutes.
            let end = ((try? FileManager.default.attributesOfItem(atPath: transcript.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            let live = ReviewLiveTracker().update(transcript: transcript, now: end)
            let activity = ReviewActivity(tool: live.mainDoing, agentsRunning: 0)
            let progress = ReviewProgress.read(folder: folder, kind: .full, activity: activity, live: live, now: end)
            DispatchQueue.main.async { model.at = end; model.progress = progress }
        }
        let host = NSHostingController(rootView: ReplayRoot(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Progress replay"
        window.setContentSize(NSSize(width: 900, height: 760))
        window.center()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            FileHandle.standardError.write(Data("replay-window \(window.windowNumber)\n".utf8))
        }
    }

    private struct ReplayRoot: View {
        @ObservedObject var model: Model
        var body: some View {
            ScrollView {
                if let progress = model.progress {
                    ReviewProgressPanel(progress: progress, since: nil, fixedNow: model.at).padding(16)
                } else {
                    Text("Reading the run…").padding(40)
                }
            }
            .frame(minWidth: 700, minHeight: 500)
        }
    }
}
